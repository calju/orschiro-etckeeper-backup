--[[
    Copyright 2010,2011 ulatencyd developers

    This file is part of ulatencyd.

    License: GNU General Public License 3 or later
]]--

---------------------------------
--! @file
--! @brief scheduler implementation
--! @ingroup lua_SCHEDULER
---------------------------------

require("posix")

--------------------------------------------------------------
-------------------- mappings parsing ------------------------

--! @name mappings parsing (internal)
--! @{

--! @brief A table holding status for each mapping `rule` during scheduler run.
--! This table is cleared every scheduler run. Each table value (with the `rule` as a key) stores:
--! - Whether the `rule` never matches, i.e., `sysflags` precheck exists and does not match, or any `check` function returned
--!   FALSE as second value.
--! - `Check` functions to be skipped, i.e., `check` functions that returned TRUE as second value.
--! - Whether skip all `check` functions, i.e., all `check` functions returned TRUE as second value.
--! @private @memberof Scheduler
local _RStat = {}

--! @brief A table holding status for each `CGroup` during scheduler run.
--! This table is cleared every scheduler run. Each table value (with the `CGroup` as a key) stores:
--! - `Adjust` functions to be skipped, i.e., `adjust` functions that returned FALSE as second value.
--! @private @memberof Scheduler
local _CStat = {}

--! @brief Initialises #_RStat and #_CStat tables; called in the beginning of every scheduler run.
--! @private @memberof Scheduler
local function _mapping_status_init()
  _RStat = setmetatable({}, { __index = _RStat_index })
  _CStat = setmetatable({}, { __index = _CStat_index })
end

--! @brief #_RStat metatable.__index
--! @private @memberof Scheduler
function _RStat_index(data, rule)
  local stat = {
    skip = false,                                                     -- skip whole rule
    skip_checks = rule.checks and { [ #rule.checks ] = nil } or {},   -- checks functions to be skipped (those always matching)
    skip_all_checks = not (rule.checks and #rule.checks > 0),         -- skip all checks functions (all always match)
  }
  if rule.sysflags then                                               -- sysflags check (checked only once)
    if not ulatency.match_flag(rule.sysflags) then
      stat.skip = true
    end
  end
  data[rule] = stat
  return stat
end

--! @brief #_CStat metatable.__index
--! @private @memberof Scheduler
function _CStat_index(data, cgroup)
  local stat = {
    skip_adjusts = cgroup.adjust and { [ #cgroup.adjust ] = nil } or {}  -- adjusts functions to be skipped
  }
  data[cgroup] = stat
  return stat
end

--! @brief Check if the process has a flag with one of given name.
--! @param labels Table with flag names to check (see `u_flag.name`)
--! @param proc A #U_PROC instance
--! @return boolean TRUE if the #U_PROC has a flag with one of `labels` names.
--! @warning don't use non alpha numeric characters in name
--! @todo build validator
--! @protected @memberof Scheduler
function check_label(labels, proc)
  for j, flag in pairs(proc:list_flags(true)) do
    for k, slabel in pairs(labels) do
      if flag.name == slabel then
        return true
      end
    end
  end
end

local _check_label = check_label

--! @private @memberof Scheduler
local function check(proc, rule)
  assert(proc)
  local stat = _RStat[rule]
  if stat.skip then
    return nil
  end
  -- sysflags are checked only once via _RStat metatable
  -- label check
  if rule.label and not _check_label(rule.label, proc) then
    return nil
  end
  -- checks
  if not stat.skip_all_checks then
    for i,c in ipairs(rule.checks) do
      if not stat.skip_checks[i] then
        local result, flag = c(proc)
        if flag ~= nil then
          if flag == true then
            stat.skip_checks[i] = true
            if #stat.skip_checks == #rule.checks then
              stat.skip_all_checks = true
            end
          else
            stat.skip = true
          end
        end
        if not result then
          return nil
        end
      end
    end
  end
  return rule
end

--! @private @memberof Scheduler
local function run_list(proc, lst)
  local rv = {}
  for key, rule in ipairs(lst) do
    local match = check(proc, rule)
    if match then
      rv[#rv+1] = match
      if match.children then
        best_subs = run_list(proc, match.children)
        --print("got bestsubs", type(best_subs), best_subs, #best_subs)
        if best_subs and #best_subs > 0 then
          for i,sub in ipairs(best_subs) do
            rv[#rv+1] = sub
          end
        else
          if match.placeholder then
            match = nil
          end
        end
      end
      if match then break end
      rv = {}
    end
  end
  return rv
end

--! @private @memberof Scheduler
local function format_name(proc, map)
  -- generates the final path for the process for the map
  if map.cgroups_name then
    if type(map.cgroups_name) == "function" then
      return map.cgroups_name(proc)
    end
    function get(name)
      return tostring(proc[name])
    end
    return string.gsub(map.cgroups_name, "%$\{([%w_]+)\}", get)
  end
  return map.name
end

--! @private @memberof Scheduler
local function build_path_parts(proc, res)
  -- build a array for 
  local rv = {}
  for i,k in ipairs(res) do
    local cname = format_name(proc, k)
    rv[#rv+1] = cname
  end
  return rv
end

--! @private @memberof Scheduler
local function create_group(proc, prefix, mapping, subsys)
  name = format_name(proc, mapping)
  if #prefix > 0 then
    path = prefix .. "/" .. name
  else
    path = name
  end

  local rv = CGroup.get_group(subsys .."/".. path)
  if rv then
    return rv
  end

  rv = CGroup.new(path, mapping.param, subsys)
  if mapping.adjusts then
    for k,v in ipairs(mapping.adjusts) do
      rv.adjust[#rv.adjust+1] = v
    end
  end

  rv:commit()  -- force commit here to set cgroup parameters before adjust_new is run or any task added.

  if mapping.adjust_new then
    mapping.adjust_new(rv, proc)
  end
  if rv:is_dirty() then
    rv:commit()
  end
  return rv
end

--! @private @memberof Scheduler
local function map_to_group(proc, parts, subsys)
  local chain = build_path_parts(proc, parts)
  local path = subsys .."/".. table.concat(chain, "/")
  local cgr = CGroup.get_group(path)

  if not cgr then
    local prefix = ""
    for i, parrule in ipairs(parts) do
      cgr = create_group(proc, prefix, parrule, subsys)
      prefix = cgr.name
    end
  end

  local skip = _CStat[cgr].skip_adjusts
  local adjust = cgr.adjust
  if (#skip ~= #adjust) then
    for i,v in ipairs(adjust) do
      if not skip[i] and v(cgr, proc) == false then
        skip[i] = true
      end
    end
  end

  return cgr
end

--! @} End of "mappings parsing"


--------------------------------------------------------------
------------------ scheduler implementation ------------------


--! @class Scheduler
--! @implements __SCHEDULER
--! @brief This is the default %scheduler implementation.
--! For %scheduler overview see @ref lua_SCHEDULER "scheduler module". For general %scheduler interface see `__SCHEDULER`
--! table documentation.
--! @details This scheduler implementation uses a decision tree based on mapping rules. These mapping rules are stored in
--! files under `conf/scheduler/`; each of this mapping represents a scheduler configuration and only one of them can be
--! active at any time. You can choose the default one in `ulatencyd.conf` or change it runtime (via ulatency client or
--! DBUS). The default configuration (mappings) is the `desktop` stored in `conf/scheduler/20-desktop.lua`. You can
--! customise this mapping or write new one.
--! @ingroup lua_SCHEDULER
Scheduler = {
  C_FILTER = false, --!< If FALSE current iteration does not skip unchanged processes. @protected @memberof Scheduler
  ITERATION = 1, --!< Scheduler iteration (range 1 - `full_run` or 15). @protected @memberof Scheduler
  INITIALIZED = false, --!< Set by `Scheduler::_init()` on first `Scheduler::all()` execution. @protected @memberof Scheduler
  PROC_BLOCK_THRESHOLD = 1, --!< `U_PROC.block_scheduler` threshold. @protected @memberof Scheduler
  _after_hooks = {} --!< Registered `after` callbacks, see `Scheduler::register_after_hook()`. @private @memberof Scheduler
}

--! @brief Initialize scheduler internals.
--! Invoked when Scheduler:all() is executed for first time.
--! - load mappings
--! - register timeout function for periodically cleaning cgroups (see `Scheduler::cgroups_cleanup()`)
--! @private @memberof Scheduler
function Scheduler:_init()
  if not self.MAPPING then
    self:load_config()
  end
  local function cgroups_cleanup()
    Scheduler:cgroups_cleanup()
  end
  ulatency.add_timeout(cgroups_cleanup, 120000) --FIXME: or run this every scheduler:all() ?
  cgroups_cleanup_full()
end

--! @private @memberof Scheduler
function Scheduler:_init_run()
  self:update_caches()
  if not self.MAPPING then
    self:load_config()
  end
  _mapping_status_init()
end

--! @brief Registers a callback function to be run after the scheduling of process(es) is finished.
--! Use this to register callbacks from mappings rules, timeout functions, filters etc.
--! Each registered callback will be triggered from `Scheduler::all()` or `Scheduler::one()` every time scheduling is
--! finished, until the callback returns FALSE.
--! @param id Unique identification of callback function. Already registered callback with same `id` will be overwritten.
--! @param func Callback function to be run after the scheduling is finished.
--! If this function will return FALSE, it will be unregistered and not run next time.
--! @public @memberof Scheduler
function Scheduler:register_after_hook( id, func )
  self._after_hooks[id] = func
  if LOG_DEBUG then u_debug(
        'Scheduler: registering after-callback with id: %s', tostring(id)) end
end

--! @brief Runs registered callbacks after the scheduling is finished.
--! @see `Scheduler::register_after_hook()`
--! @private @memberof Scheduler
function Scheduler:_run_after_hooks()
  local callbacks = self._after_hooks
  for id,cb in pairs(callbacks) do
    if LOG_DEBUG then u_debug(
          'Scheduler: run registered after-callback with id: %s',
          tostring(id)) end
    if not cb() then callbacks[id]=nil end
  end
end

--! @brief Schedules all changed processes, called on every iteration.
--! @details Implements the __SCHEDULER::all() with following extensions:
--! - Schedules all processes if it has been run `full_run` times (as defined in configuration file) or 15 times since
--!   the last full run.
--! - If @link __SYSTEM_FLAG_SUSPEND `suspend`@endlink or @link __SYSTEM_FLAG_QUIT`quit`@endlink system flag is set,
--!   the `Scheduler::_quit()` is invoked with that flag passed, after processes were scheduled.
--! - If @link __SYSTEM_FLAG_CLEANUP `cleanup`@endlink system flag is set (by `Scheduler::_quit()`), the
--!   `quit` and `suspend` flags are ignored as the shutdown is already in progress.
--! @public @memberof Scheduler
function Scheduler:all()

  if not self.INITIALIZED then
    self:_init()
    self.INITIALIZED = true
  end

  if ulatency.get_flags_changed() then
    self.C_FILTER = false
  end
  for j, flag in pairs(ulatency.list_flags()) do
    if flag.name == "pressure" or flag.name == "emergency" then
      self.C_FILTER = false
    end
  end
  if self.ITERATION > (tonumber(ulatency.get_config("scheduler", "full_run") or 15)) then
    self.C_FILTER = false
    self.ITERATION = 1
  end
  -- list only changed processes
  self:_init_run()

  if LOG_DEBUG then u_debug(
        "scheduler filter: %s", tostring(self.C_FILTER)) end

  for k,proc in ipairs(ulatency.list_processes(self.C_FILTER)) do
    --print("sched", proc, proc.cmdline)
    self:_one(proc, false)
  end
  self:_run_after_hooks()
  self.C_FILTER = true
  self.ITERATION = self.ITERATION + 1

  for j, flag in pairs(ulatency.list_flags()) do
    -- shutdown
    if flag.name == "suspend" or flag.name == "quit" then
      self:_quit( flag )
      break
    end
    -- startup: first scheduler run
    if flag.name == "startup" then
      ulatency.del_flag(flag)
    end
  end

  return true
end

--! @brief Finishes the scheduler shutdown and quits the ulatencyd daemon.
--!
--! -# Destroys created cgroups if the name of passed flag is "quit", that is,
--!    the @link __SYSTEM_FLAG_QUIT`quit`@endlink system flag is passed.
--!   -# Tries to load `cleanup` mappings and runs `Scheduler:all()` one more time.
--! -# Quits the daemon via without dispatching remaining main loop events (`ulatency.die()`).
--!
--! @param u_flag flag System flag that caused the shutdown.
--! @warning Do not call this function directly as filters and active scheduler mapping won't be given chance
--! to cleanup.
--! @note The preferred way of quitting ulatencyd daemon is to add `quit` or `suspend` system flag,
--! set system_flags_changed (`ulatency.set_flags_changed(1)`) and force iteration (`ulatency.run_iteration()`).
--! Or use `ulatency.quit()` for convenience. This
--! way all filters and active scheduler mappings will be given chance to react (e.g. unfreeze
--! frozen cgroups of the freezer subsystem).  Scheduler will then call this function with the
--! guilty system flag passed as argument.
--! @private @memberof Scheduler
function Scheduler:_quit(flag)
  if flag then
    ulatency.del_flag(flag)
    if flag.name == "quit" then
      -- cleanup cgroups
      u_info("scheduler: cleaning up")
      if self:load_config("cleanup") then
        self.PROC_BLOCK_THRESHOLD = 2   --cleanup cgroups with blocked processes
        ulatency.set_flags_changed(1)
        self:all() -- cleanup round with "cleanup" scheduler config
      else
        u_warning("Could not switch to cleanup mapping. CGroups are not cleaned up!")
      end
    end
  end
  self:cgroups_cleanup(true)
  -- restore the autogrouping
  if posix.access("/proc/sys/kernel/sched_autogroup_enabled") == 0 then
    u_info("restoring sched_autogroup in linux kernel")
    ulatency.restore_sysctl("kernel.sched_autogroup_enabled")
  end
  ulatency.die(flag.threshold or flag.name == "suspend" and 1 or 0)
end

--! @public @memberof Scheduler
function Scheduler:load_config(name)
  if not name then
    name = ulatency.get_config("scheduler", "mapping")
    if not name then
      u_error("no default scheduler config specified in config file")
    end
  end
  u_info("Scheduler use mapping: %s", name)
  local mapping_name = "SCHEDULER_MAPPING_"..string.upper(name)
  MAPPING = getfenv()[mapping_name]
  if not MAPPING then
    if not self.MAPPING then
      u_error("invalid mapping: %s", mapping_name)
    else
      u_warning("invalid mapping: %s", mapping_name)
    end
    return false
  end
  if LOG_DEBUG then u_debug("use scheduler map \n%s", to_string(MAPPING)) end
  self.MAPPING = MAPPING
  self.CONFIG_NAME = name

  -- initialize rules

  local omitted_params = {}
  local function _initialize_rules (rules, subsys, parent_rules)
    for key, rule in ipairs(rules) do
      local rule_path = parent_rules and parent_rules..'/'..rule.name or
                        rule.name
      -- merge adjust() and check() functions to adjusts and checks tables
      for _,k in ipairs({"adjust", "check"}) do
        if rule[k] then
          local ks = k.."s"
          if not rule[ks] then
            rule[ks] = { rule[k] }
          else
            rule[ks][ #rule[ks] + 1] = rule[k]
          end
          rule[k] = nil
        end
      end
      -- recalculate values of cgroup parameters
      if rule.param then
        for param, val in pairs(rule.param) do
          rule.param[param] = CGroup.get_recalc_value(subsys, param, val)
          if LOG_DEBUG and
             val and tostring(val) ~= tostring(rule.param[param]) then u_debug(
                "mapping %s[%s], rule %s: "..
                "Adjust cgroup parameter %s from %s to %s.",
                self.CONFIG_NAME, subsys, rule_path,
                param, val, rule.param[param] or "nil" ) end
          if LOG_WARNING and val and not rule.param[param] then
            -- remember omitted parameters
            local key = "subsys "..subsys..", param "..param
            omitted_params[key] = omitted_params[key] or {}
            table.insert(omitted_params[key], string.format(
                  "rule %s, value %s", rule_path, val ))
          end
        end
      end
      -- initialize children rules
      if rule.children then
        _initialize_rules (rule.children, subsys, rule_path)
      end
    end -- each rule
  end

  for x,subsys in ipairs(ulatency.get_cgroup_subsystems()) do
    map = self.MAPPING[subsys] or SCHEDULER_MAPPING_DEFAULT[subsys]
    if map then
      _initialize_rules(map, subsys)
    end
  end

  -- log omitted cgroup parameters
  if LOG_WARNING then
    local output = {}
    for key, vals in pairs(omitted_params) do
      output[#output+1] = key..': '..table.concat(vals, "; ")
    end
    if #output > 0 then
      output = table.concat(output, "\n")
      u_warning(
            "Some cgroup parameters were omitted from the mapping:\n%s", output)
    end
  end

  return true
end

--! @protected @memberof Scheduler
function Scheduler:update_caches()
  Scheduler.meminfo = ulatency.get_meminfo()
  Scheduler.vminfo = ulatency.get_vminfo()
end

--! Schedules one process, a wrapper around `Scheduler::_one()`
--! @public @memberof Scheduler
function Scheduler:one(proc)
  self:_init_run()
  local rv = self:_one(proc, true)
  self:_run_after_hooks()
  return rv
end

--! @private @memberof Scheduler
function Scheduler:_one(proc, single)
  if not self.MAPPING then
    self:load_config()
  end

  local group
  if proc.block_scheduler >= self.PROC_BLOCK_THRESHOLD then
    if LOG_DEBUG then u_debug(
          "Scheduler:one(): pid %d skipped "..
          "(proc.block_scheduler=%d, block threshold=%d)",
          proc.pid, proc.block_scheduler, self.PROC_BLOCK_THRESHOLD) end
  else
    for x,subsys in ipairs(ulatency.get_cgroup_subsystems()) do
      map = self.MAPPING[subsys] or SCHEDULER_MAPPING_DEFAULT[subsys]
      if map and ulatency.tree_loaded(subsys) then

        -- skip foreign cgroups
        local cgr_path = proc:get_cgroup(subsys)
        if not cgr_path then
          if not proc.is_vanished and ulatency.is_pid_alive(proc.pid) then
            if LOG_WARNING then u_warning(
                  "no cgroup for process, assuming '/' - "..
                  "subsys: %s, pid: %d, cmdfile: %s, exe: %s",
                  subsys, proc.pid, proc.cmdfile or "NONE",
                  proc.exe or "NONE") end
            cgr_path = '/'
          else
            -- process is already dead
            proc:clear_changed()
            return true
          end
        end
        if CGroup.is_foreign(subsys, cgr_path) then
          if LOG_INFO then u_info(
                "scheduler subsys %s: skipping %s (pid: %d) "..
                "because its cgroup %s is foreign",
                subsys, proc.cmdfile or "unknown", proc.pid,
                subsys..cgr_path)
          end
        else

          local mappings = run_list(proc, map)
          --pprint(mappings)
          group = map_to_group(proc, mappings, subsys)
          --print(tostring(group))
          --pprint(mappings)
          --print(tostring(proc.pid) .. " : ".. tostring(group))
          if group then
            if group:is_dirty() then
              group:commit()
            end
            --print("add task", proc.pid, group)
            -- get_current_tasks can fail if the process is already dead
            local tasks = proc:get_current_task_pids(true)
            if tasks then
              group:add_task_list(proc.pid, tasks)
              group:commit()
            end
          elseif LOG_DEBUG then u_debug(
                "no group found for: %s subsystem %s", tostring(proc), subsys)
          end
        end
      end
    end
    proc:clear_changed()
    --pprint(build_path_parts(proc, res))
  end
  if single then
      self:_run_after_hooks()
  end
  return true
end

--! @public @memberof Scheduler
function Scheduler:list_configs()
  rv = {}
  for k,v in pairs(getfenv()) do
    if string.sub(k, 1, 18 ) == "SCHEDULER_MAPPING_" then
      name = string.lower(string.sub(k, 19))
      if v.info then
        if not v.info.hidden then
          rv[#rv+1] = name
        end
      else
        rv[#rv+1] = name
      end
    end
  end
  return rv
end

--! @public @memberof Scheduler
function Scheduler:get_config_description(name)
  name = string.upper(name)
  local mapping = getfenv()["SCHEDULER_MAPPING_" .. name]
  if mapping and mapping.info then
    return mapping.info.description
  end
end

--! @public @memberof Scheduler
function Scheduler:set_config(config)
  if ulatency.get_config("scheduler", "allow_reconfigure") ~= 'true' then
    ulatencyd.log_info("requested scheduler reconfiguration denied")
    return false
  end
  local rv = self:load_config(config)
  if rv then
    self.C_FILTER = false
    ulatency.run_iteration()
  end
  return rv
end

--! @public @memberof Scheduler
function Scheduler:get_config()
  if self.CONFIG_NAME then
    return string.lower(self.CONFIG_NAME)
  end
  return nil
end

-- cgroups cleanup
local CGROUPS_CLEANUP_SCHEDULED = false
local function _cgroups_cleanup()
  if LOG_DEBUG then u_debug("Scheduler: cleaning cgroups.") end
  local to_preserve, to_remove = {}, {}
  local groups = CGroup.get_groups()
  CGROUPS_CLEANUP_SCHEDULED = false

  for n, c in pairs(groups) do
    if c:can_be_removed() then
      to_remove[#to_remove + 1] = n
    else
      to_preserve[#to_preserve + 1] = n .. "/"
    end
  end
  local remove = {}
  for i,r_grp in ipairs(to_remove) do
    local needed = false
    for _, p_grp in ipairs(to_preserve) do
      if #r_grp+1 < #p_grp and string.sub(p_grp, 1, #r_grp+1) == r_grp .. '/' then
        needed = true
        break
      end
    end
    if not needed then
      remove[#remove+1] = { #r_grp:split("/"), r_grp }
    end
  end
  table.sort(remove, function(a,b) return a[1] > b[1] end)
  for _,v in ipairs(remove) do
    if groups[v[2]]:remove() then
      groups[v[2]] = nil
    end
  end
end

-- full cleanup (need to be executed only once on daemon start)
-- called from Scheduler:_init()
function cgroups_cleanup_full()
  u_debug("cleaning all cgroups")
  for _, subsys in ipairs(ulatency.get_cgroup_subsystems()) do
    local priv_root = CGROUP_PRIVATE_ROOT..subsys..'/'
    local root = CGROUP_ROOT..subsys..'/'
    if posix.access(priv_root) == 0 then

      local function rmdir_cgroups(priv_dir, dir)
        for f in posix.files(priv_dir) do
          if f ~= '.' and f ~= '..' then
            local stat=posix.stat(priv_dir..f)
            if stat and stat.type == 'directory' then
              rmdir_cgroups(priv_dir..f..'/', dir..f..'/')
            end
          end
        end

        local cleared = true
        if posix.access(dir) == 0 then
          cleared = posix.rmdir(dir)
        end

        if cleared then
          if posix.rmdir(priv_dir) and LOG_DEBUG then
            u_debug("removed unused cgroup: %s", dir)
          end
        end

      end

      rmdir_cgroups(priv_root, root)

    end
  end
end

--! @public @memberof Scheduler
function Scheduler:cgroups_cleanup(instant)
  if not self.INITIALIZED then return end
  if instant then
    _cgroups_cleanup()
  elseif not CGROUPS_CLEANUP_SCHEDULED then
    CGROUPS_CLEANUP_SCHEDULED = true
    ulatency.add_timeout(_cgroups_cleanup, 2000)
  end
end

--! @brief scheduler instance
--! @public @memberof ulatency
ulatency.scheduler = Scheduler

ulatency.load_rule_directory("scheduler/")

-- add startup system flag
local startup_flag = ulatency.new_flag("startup")
ulatency.add_flag(startup_flag)
