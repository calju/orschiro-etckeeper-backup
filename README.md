# Workflow to push your /etc to Github

1. Initialise a new repo `$ sudo etckeeper init`.

2. Make sure your root account does have an authorised ssh key to be able to push to Github.

3. Add the file `/etc/etckeeper/commit.d/60-github-push` with the following content and make it executable:
```
#!/bin/sh 
set -e
if [ "$VCS" = git ] && [ -d .git ]; then   
  cd /etc/   
  git push origin master 
fi
```
4. You can now regularly push your changes to Github using `$ sudo etckeeper commit "My commit."`.
