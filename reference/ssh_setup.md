# SSH setup (one-time, per machine)

The whole skill assumes an SSH alias with connection multiplexing, so you type your OTP/credential once per session and every later `ssh`/`rsync`/`scp` rides the same socket without re-prompting. Add this block to `~/.ssh/config` and set `HPC_HOST` in `hpc.env` to the alias.

## GenomeDK

```
Host genomedk
	Hostname login.genome.au.dk
	User <your-username>
	ControlMaster auto
	ControlPath ~/.ssh/cm-%r@%h:%p
	ControlPersist 12h
	ServerAliveInterval 60
	ServerAliveCountMax 3
```

- `ControlMaster auto` + `ControlPath` + `ControlPersist 12h` are what let `hpc_login.sh` warm a socket that survives ~12 h. Without them, every command re-prompts for the OTP. `hpc_login.sh` runs `ssh -G <host>` on startup and prints a warning pointing back here if multiplexing is not configured for `HPC_HOST` — so a missing or incomplete `Host` block surfaces as one clear message rather than a confusing "could not resolve hostname" error or a repeated OTP prompt.
- `bash hpc_login.sh` authenticates once (you type the OTP); after that, `ssh -O check <host>` reports the live socket and the wrappers skip the prompt.
- The two-factor login cannot be automated. The human types the OTP. The assistant should always probe first (`ssh -O check`, or `ssh -o BatchMode=yes <host> true`) and only ask the human to run `bash hpc_login.sh` when the probe fails — if you are on a whitelisted IP, re-login may be no-friction.
- **First login only:** GenomeDK requires two-factor enrollment on the very first login (install an authenticator app, then scan the QR from `gdk-auth-show-qr`). Without it you cannot access the account. Full walkthrough: <https://genome.au.dk/docs/getting-started/>.

## Other SLURM clusters

Any cluster reachable by plain SSH (password, key, or OTP) works the same way: add a `Host` block with the multiplexing options above and point `HPC_HOST` at it. Set `HPC_ACCOUNT`, `HPC_PARTITION`, and `HPC_REMOTE_ROOT` for that cluster.

Clusters behind a bastion or a tunnel client (for example Teleport `tsh`, as on the Gefion DGX cluster) need a different login hop and are out of scope for these wrappers, but the push / submit / fetch logic still applies once you can `ssh`/`rsync` to a login node. The cleanest adaptation is a `Host` block whose `ProxyCommand` runs the tunnel, so the alias behaves like a normal SSH host.
