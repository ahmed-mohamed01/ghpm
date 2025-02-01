# GitHub Package Installer

This is a github package manager that will allow you to install and manage pre-compiled binaries from github releases.
It allows you to provice a  GitHub repository in the form of owner/repo-name, and it will automatically fetch, validate and install the binaries
It is meant to simplify the process of installation and management of simple cli tools such as zoxide or fzf, and would not be suitable for anything more complex.

I used this as practice while learning bash, so there are bound to be errors. 

## Why? What is it all for?
I found myself having to install brew or similar if I wanted the latest version of a binary.
Versions of fzf, eza, bat etc on APT are woefully out of date, and update process to get a more recent version is a nightmare. Manually installing and managing these files is a chore.

This is where ghpm comes in. It will allow you to provide the GitHub repo in the form of owner/repo, and it will automatically fetch, validate and install the binaries. You will be able to remove/update and otherwise manage the binaries installed with this script.

This is meant to be used for (ideally) statically linked, standalone binaries. 
While it does allow you to search for dependencies for repos, I have not extensively tested this functionality; my main use case has been managing simple tools like fzf, bat, rg etc, all of which are statically linked.

It will not work with tools that need systemd, or need deeper kernel access. It will not work with tools that need to make changes to system files or need to access non-standard locations. In these cases, use the tools developers provided to install them. 

## Is it dangerous?
The script does not make changes to system that are not reversible, and does not write to any system directories.
All binaries are installed to $HOME/.local/bin
Completions and man pages are installed  to $HOME/.local/share

It maintains a database of files it has copied, these are removed when package is removed with ```ghpm remove [package]```.

## Features
- allows installation of pre-compiled binaries from github
- update and remove installed packages.
- validates binaries, and checks dependencies before they are installed
- allows batch installation from a file, ```ghpm --file [filename]```
- allows listing of installed packages, ```ghpm --list```

### Usage examples: 
```bash
# Standalone install 
$ ghpm install eza-community/eza

Repo: zyedidia/micro
Latest version: v2.0.14
Release asset: micro-2.0.14-linux64-static.tar.gz
Files to install:
    micro                --> /home/ahmed/ghpm/.local/bin/micro
    micro.1              --> /home/ahmed/ghpm/.local/share/man/man1/micro.1

Proceed with installation? [y/N]: y
Installing files...
Installed binary: /home/ahmed/ghpm/.local/bin/micro
Installed man page: /home/ahmed/ghpm/.local/share/man/man1/micro.1

# Batch install from a file. 
$ ghpm -f repos.txt

Processing (4) repositories from repos.txt:

Binary               Github          APT             Asset/Notes                                       
-----------------------------------------------------------------------------------------------
zoxide               0.9.6           not found       zoxide-0.9.6-x86_64-unknown-linux-musl.tar.gz
rg                   14.1.1          not found       skipped: installed, up to date
fnm                  source          not found       skipped: source only
non-existent/repo    -               -               skipped: repo not found

Repos to install:
    ajeetdsouza/zoxide (0.9.6)

Dependencies needed:
    None

Install all repos? [y/N]
# Display installed applications 
$ ghpm --list

Packages managed by this script:

Package         Version      Location
-------------------------------------------------------
eza             v0.20.16     /home/ahmed/ghpm/.local/bin/eza
micro           v2.0.14      /home/ahmed/ghpm/.local/bin/micro
lazygit         v0.45.0      /home/ahmed/ghpm/.local/bin/lazygit

```

## Dependencies

- `curl`: For making HTTP requests to GitHub API
- `jq`: For JSON parsing and cache management
