# Feature Specification: Automatic Goose acquisition

The ZATCA master migration command shall use an explicit operator-provided Goose
binary when configured, otherwise use `goose` from `PATH`, and otherwise
download a source-pinned, checksum-verified Linux Goose binary into the
deployment state cache. The existing migration artifact remains external and
required.

See `requirements.md` for complete requirements and acceptance criteria.
