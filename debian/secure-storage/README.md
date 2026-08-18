# Debian Secure Storage

The executable entrypoint is:

```bash
sudo ./setup.sh
```

This tool provisions a file-backed LUKS2 filesystem with automatic unlock and mount, plus optional encrypted swap and encrypted Docker/containerd persistent storage.

For complete usage, flags, architecture, reboot validation, and recovery instructions, see:

[`../../docs/debian/secure-storage.md`](../../docs/debian/secure-storage.md)
