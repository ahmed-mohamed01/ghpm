# GitHub Package Installer

This is a github package manager that will allow you to install and manage pre-compiled binaries from github releases.
It allows you to provice a  GitHub repository in the form of owner/repo-name, and it will automatically fetch, validate and install the binaries
It is meant to simplify the 
I used this as practice while learning bash, so there are bound to be errors. 

## Why? What is it all for?
I found myself having to install brew or similar if I wanted the latest version of a binary.
For some cli tools that I use freaquently, such as zoxide or fzf, latest apt versions seeem to be missing a lot of features.
Manually installing and managing these files is a chore.

This is meant to be used for (ideally) statically linked, standalone binaries. 
It will not work with tools that need systemd, or need deeper kernel access. In these cases, use the tools developers provided to install them. 

## Is it dangerous?
The script does not make changes to system that are not reversible, and does not write to any system directories.
All binaries are installed to $HOME/.local/bin
Completions and man pages are installed  to $HOME/.local/share

It maintains a database of files it has copied, these are removed when package is removed with ghpm remove [package].

## Features
- allows installation of pre-compiled binaries from github
- update and remove functions.
- validates binaries before they are installed

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
$ ghpm --file repos.txt
Processing (0) repositories from repos.txt:

Checking repositor data...
Binary          Github       APT          Asset                                             
------------------------------------------------------------------------------------------------
zoxide          v0.9.6       v0.4.3       zoxide-0.9.6-x86_64-unknown-linux-musl.tar.gz     
bat             v0.25.0      v0.19.0      bat-v0.25.0-x86_64-unknown-linux-gnu.tar.gz       
fd              v10.2.0      not found    fd-v10.2.0-x86_64-unknown-linux-gnu.tar.gz        
ripgrep         14.1.1       v13.0.0      ripgrep-14.1.1-i686-unknown-linux-gnu.tar.gz      
fzf             v0.57.0      v0.29.0      fzf-0.57.0-linux_amd64.tar.gz                     
eza             v0.20.16     not found    eza_x86_64-unknown-linux-gnu.tar.gz               
lazygit         v0.45.0      not found    lazygit_0.45.0_Linux_x86_64.tar.gz                
tldr-c-client   v1.6.1       not found                                                      
micro           v2.0.14      v2.0.9       micro-2.0.14-linux64-static.tar.gz                

Needed dependencies: none

Installation options:
1. Install all GitHub versions (to /home/ahmed/ghpm/.local/bin)
2. Install all APT versions
3. Cancel
Select installation method [1-3]:

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
