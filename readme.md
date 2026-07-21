# ADDMOBILE Server Setup Script

![ADDMOBILE_IMAGE](add_mobile.png)

## Installation 

Optional: Set environment variable
`~/.bashrc`
```
GATEWAY_URL=<your gateway url>
```


Install: Run the following in bash
```
$ bash -c "$(curl -fsSL https://raw.githubusercontent.com/addmobile/setup/refs/heads/main/setup.sh)"
```

## Uninstall

This will stop and remove mobile-pod
```
bash -c "$(curl -fsSL https://raw.githubusercontent.com/addmobile/setup/refs/heads/main/clear.sh)"
```
