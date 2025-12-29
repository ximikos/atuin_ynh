# Administration

## User registration

User registration is disabled by default.

You can enable or disable registrations using the YunoHost configuration panel:

- Web admin → Applications → Atuin → Configuration → Registration

This setting controls the `open_registration` option in `server.toml` and is applied automatically by restarting the Atuin service.

### Command-line alternative

If needed, registrations can also be managed manually:

Enable registration:
```
sudo sed -i 's/^open_registration = .*/open_registration = true/' __INSTALL_DIR__/server.toml
sudo yunohost service restart __APP__
```

Disable registration:
```
sudo sed -i 's/^open_registration = .*/open_registration = false/' __INSTALL_DIR__/server.toml
sudo yunohost service restart __APP__
```

## Logs and troubleshooting

View service logs:
```
sudo journalctl -u __APP__ -f -l
```
You can also get the latest logs from the webadmin, in its [service page](#/services/__APP__).

