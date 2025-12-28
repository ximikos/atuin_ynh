## Registration is disabled by default
This package installs Atuin with:
- `open_registration = false`
That means new users **cannot** register until you enable registration manually.

### Enable registration (temporarily)
```bash
sudo sed -i 's/^open_registration = .*/open_registration = true/' __DATA_DIR__/server.toml
sudo yunohost service restart __APP__
```
Now users can register using the Atuin client.

### Disable registration
```bash
sudo sed -i 's/^open_registration = .*/open_registration = true/' __INSTALL_DIR__/server.toml
sudo yunohost service restart __APP__
```
## Troubleshooting
```bash
sudo journalctl -u __APP__ -f -l
```
You can also get the latest logs from the webadmin, it its [service page](#/services/__APP__).
