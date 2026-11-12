// C ABI declarations kept in sync with src/heming_audio.h.
// ignore_for_file: non_constant_identifier_names
import 'dart:ffi' as ffi;

@ffi.Native<ffi.Pointer<ffi.Void> Function()>()
external ffi.Pointer<ffi.Void> hm_preview_create();
@ffi.Native<ffi.Void Function(ffi.Pointer<ffi.Void>)>()
external void hm_preview_destroy(ffi.Pointer<ffi.Void> handle);
@ffi.Native<ffi.Int Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Char>)>()
external int hm_preview_open(
  ffi.Pointer<ffi.Void> handle,
  ffi.Pointer<ffi.Char> path,
);
@ffi.Native<ffi.Int Function(ffi.Pointer<ffi.Void>, ffi.Int64)>()
external int hm_preview_play(ffi.Pointer<ffi.Void> handle, int epoch);
@ffi.Native<ffi.Void Function(ffi.Pointer<ffi.Void>)>()
external void hm_preview_pause(ffi.Pointer<ffi.Void> handle);
@ffi.Native<ffi.Int Function(ffi.Pointer<ffi.Void>, ffi.Int64, ffi.Int64)>()
external int hm_preview_seek(
  ffi.Pointer<ffi.Void> handle,
  int positionMs,
  int epoch,
);
@ffi.Native<ffi.Void Function(ffi.Pointer<ffi.Void>)>()
external void hm_preview_stop(ffi.Pointer<ffi.Void> handle);
@ffi.Native<ffi.Int64 Function(ffi.Pointer<ffi.Void>)>()
external int hm_preview_interrupt(ffi.Pointer<ffi.Void> handle);
@ffi.Native<ffi.Void Function(ffi.Pointer<ffi.Void>, ffi.Double)>()
external void hm_preview_volume(ffi.Pointer<ffi.Void> handle, double volume);
@ffi.Native<ffi.Pointer<ffi.Char> Function(ffi.Pointer<ffi.Void>)>()
external ffi.Pointer<ffi.Char> hm_preview_status(ffi.Pointer<ffi.Void> handle);

@ffi.Native<ffi.Pointer<ffi.Void> Function()>()
external ffi.Pointer<ffi.Void> hm_create();
@ffi.Native<ffi.Void Function(ffi.Pointer<ffi.Void>)>()
external void hm_destroy(ffi.Pointer<ffi.Void> engine);
@ffi.Native<ffi.Int64 Function()>()
external int hm_now_us();
@ffi.Native<
  ffi.Int32 Function(
    ffi.Pointer<ffi.Void>,
    ffi.Pointer<ffi.Char>,
    ffi.Pointer<ffi.Char>,
    ffi.Pointer<ffi.Char>,
    ffi.Int32,
  )
>()
external int hm_prepare_local(
  ffi.Pointer<ffi.Void> engine,
  ffi.Pointer<ffi.Char> path,
  ffi.Pointer<ffi.Char> session,
  ffi.Pointer<ffi.Char> task,
  int port,
);
@ffi.Native<
  ffi.Int32 Function(
    ffi.Pointer<ffi.Void>,
    ffi.Pointer<ffi.Char>,
    ffi.Int32,
    ffi.Pointer<ffi.Char>,
    ffi.Pointer<ffi.Char>,
  )
>()
external int hm_prepare_remote(
  ffi.Pointer<ffi.Void> engine,
  ffi.Pointer<ffi.Char> host,
  int port,
  ffi.Pointer<ffi.Char> session,
  ffi.Pointer<ffi.Char> task,
);
@ffi.Native<ffi.Void Function(ffi.Pointer<ffi.Void>)>()
external void hm_stop(ffi.Pointer<ffi.Void> engine);
@ffi.Native<ffi.Void Function(ffi.Pointer<ffi.Void>)>()
external void hm_interrupt(ffi.Pointer<ffi.Void> engine);
@ffi.Native<ffi.Void Function(ffi.Pointer<ffi.Void>, ffi.Int64)>()
external void hm_latency_compensation(
  ffi.Pointer<ffi.Void> engine,
  int microseconds,
);
@ffi.Native<ffi.Int32 Function(ffi.Pointer<ffi.Void>, ffi.Int64)>()
external int hm_schedule(ffi.Pointer<ffi.Void> engine, int time);
@ffi.Native<
  ffi.Void Function(ffi.Pointer<ffi.Void>, ffi.Double, ffi.Int32, ffi.Int32)
>()
external void hm_output(
  ffi.Pointer<ffi.Void> engine,
  double volume,
  int channel,
  int muted,
);
@ffi.Native<ffi.Pointer<ffi.Char> Function(ffi.Pointer<ffi.Void>)>()
external ffi.Pointer<ffi.Char> hm_status(ffi.Pointer<ffi.Void> engine);
@ffi.Native<ffi.Pointer<ffi.Char> Function(ffi.Pointer<ffi.Char>, ffi.Int32)>()
external ffi.Pointer<ffi.Char> hm_probe(ffi.Pointer<ffi.Char> path, int verify);
@ffi.Native<ffi.Void Function(ffi.Pointer<ffi.Void>)>()
external void hm_free(ffi.Pointer<ffi.Void> pointer);
@ffi.Native<
  ffi.Pointer<ffi.Void> Function(ffi.Pointer<ffi.Char>, ffi.Pointer<ffi.Char>)
>()
external ffi.Pointer<ffi.Void> hm_convert(
  ffi.Pointer<ffi.Char> input,
  ffi.Pointer<ffi.Char> output,
);
@ffi.Native<ffi.Pointer<ffi.Char> Function(ffi.Pointer<ffi.Void>)>()
external ffi.Pointer<ffi.Char> hm_conversion_status(ffi.Pointer<ffi.Void> job);
@ffi.Native<ffi.Void Function(ffi.Pointer<ffi.Void>)>()
external void hm_conversion_cancel(ffi.Pointer<ffi.Void> job);
@ffi.Native<ffi.Void Function(ffi.Pointer<ffi.Void>)>()
external void hm_conversion_destroy(ffi.Pointer<ffi.Void> job);
