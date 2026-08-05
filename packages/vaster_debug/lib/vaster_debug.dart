/// Time-travel debugging for Vaster programs.
///
/// Builds on `vaster_replay`'s recorded envelopes: the journal tier answers
/// instantly and purely; the materialized tier re-executes against the model
/// tape with divergence verification.
library;

export 'src/debug_session.dart';
