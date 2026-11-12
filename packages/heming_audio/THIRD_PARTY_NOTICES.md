# Native dependency

`src/vendor/miniaudio.h` is vendored unchanged from miniaudio **0.11.26**.

- Source: https://raw.githubusercontent.com/mackron/miniaudio/0.11.26/miniaudio.h
- SHA-256: `6b376c7fbb1352ba1e0e432ab66069b335ea9405e45cb6c30b97ef0f3c9c3e0e`
- Upstream: https://github.com/mackron/miniaudio
- License choice: MIT No Attribution. Full upstream license is embedded at the end of the header; its bundled dr_flac, dr_wav and dr_mp3 notices remain intact.

The application does not bundle the host computer's FFmpeg executable. PCM-to-FLAC verbatim framing is implemented from RFC 9639 in this package. Platform media decoders supply additional OS-supported formats through `heming_platform`.
