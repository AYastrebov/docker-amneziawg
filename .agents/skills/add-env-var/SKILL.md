---
name: add-env-var
description: Add, rename or change the default of an environment variable in the docker-amneziawg container — wiring it through init-amneziawg-confs/run, persistence and change detection, AWG params save/load, templates or the peer-conf awk insertion, docs and tests. Use when a task introduces a new env var (AWG_*, IP6_*, USE_*, PEER*, etc.), changes how an existing one is defaulted or persisted, or asks why changing a variable did not regenerate configs.
---

# Add an environment variable

All config generation lives in `root/etc/s6-overlay/s6-rc.d/init-amneziawg-confs/run`. Work through the steps that apply, in order.

1. **Default.** Set it in the main logic section of the run script. `local` is invalid there. Two exceptions:
   - `AWG_VERSION`-dependent defaults go inside `generate_awg_params()`, after `load_awg_params()`. Defaulting early makes the saved-value fallback dead code.
   - Values that are IPv6-related go in `root/app/ipv6-lib.sh`, not the run script.
2. **Persistence.** If a change must regenerate configs:
   - Add `ORIG_<NAME>` to `save_vars()`.
   - Add the comparison to the change-detection `if` block. Missing it means "I changed X and nothing happened".
3. **AWG parameter.** Also add it to the save block in `generate_awg_params()` and to the `grep`/`cut` section of `load_awg_params()`. Never `source` the file, because it would override Docker env vars.
4. **Output.** Pick the place by where the value is written:
   - Templates in `root/defaults/` (eval+heredoc, `${VAR}`). Templates are user-owned copies, so a literal policy change there needs a migration. Prefer an expanded placeholder.
   - Server conf: `append_awg_signatures()` / `append_awg3_params()` / `append_awg31_options()`.
   - Peer confs: the `*_to_interface()` variants, which insert into `[Interface]` before `[Peer]` with awk.
5. **Empty values.** s6 drops empty variables, so `X=` reaches the script as unset. If the user needs a way to turn the feature off, use an explicit value such as `off`. Normalize aliases like `normalize_awg_switch()` does, and drop bad values with a warning.
6. **Docs.** Add a row to the parameter table in `README.md`, a commented example in `docker-compose.yml`, and an Unreleased entry in `CHANGELOG.md`.
7. **Tests.**
   - IPv6 logic: add a case to `tests/ipv6-lib.test.sh`.
   - Generated output: add an assertion to `tests/smoke.sh`.
   - Run both:
     ```bash
     bash tests/ipv6-lib.test.sh
     docker build -t test-image . && bash tests/smoke.sh
     ```

Rules that constrain specific variables (AWG versions, S/H/I parameters, IPv6) are in `docs/development.md`.
