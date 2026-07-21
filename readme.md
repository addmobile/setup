# ADDMOBILE Server Setup Script

## Installation 

### Optional: Set environment variable

`~/.bashrc`
```
GATEWAY_URL=<your gateway url>
```

Run the following in bash
```
$ bash -c "$(curl -fsSL https://raw.githubusercontent.com/addmobile/setup/refs/heads/main/setup.sh)"
```

## Uninstall

This will stop and remove the pod
```
bash -c "$(curl -fsSL https://raw.githubusercontent.com/addmobile/setup/refs/heads/main/clear.sh)"
```
