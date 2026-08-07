## 0.5.0

- A3: disk mounts export EMPTY by contract — their bytes survive by
  nature and the checkpoint carries the mount PATH (Rule 8's
  descriptors-are-state discipline), stated in code instead of implied
  by a downcast in the checkpoint.

- Rule 11 V4: `writeText`/`writeBytes` return the bytes written.

## 0.2.0

- Initial version.
