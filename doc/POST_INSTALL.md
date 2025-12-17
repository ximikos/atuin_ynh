This is a dummy disclaimer to display after the install

The app url is <https://__DOMAIN____PATH__>

The app install dir is `__INSTALL_DIR__`

The app id is `__ID__`

# Post-install notes: Atuin server

## Registration is disabled by default

This package installs Atuin with:

- `open_registration = false`

That means new users **cannot** register until you enable registration manually.

---

## Enable registration (temporarily)

Run:

```bash
sudo sed -i 's/^open_registration = .*/open_registration = true/' /home/yunohost.app/atuin/server.toml
sudo systemctl restart atuin
```

Now users can register using the Atuin client (for example):

```bash
atuin register
```

## Disable registration

```bash
sudo sed -i 's/^open_registration = .*/open_registration = false/' /home/yunohost.app/atuin/server.toml
sudo systemctl restart atuin
```

## Troubleshooting

```bash
sudo journalctl -u atuin -f -l
```

