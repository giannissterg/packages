/// llama.cpp server backend for the VasterModel interface, with real
/// (state-addressed) KV-cache slot control.
///
/// Run the server with slot persistence enabled:
/// ```sh
/// llama-server -m model.gguf --slot-save-path /tmp/llama_slots
/// ```
library;

export 'src/llama_cpp_kv_cache_controller.dart';
export 'src/llama_cpp_vaster_model.dart';
