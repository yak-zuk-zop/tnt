# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.2] - 2025-11-24

### Added

- added worker start behaviour (link, monitor, nolink)
- returnes the expected message size in the decoding function in case of an incompleted message

### Fixed

- increased tcp buffer size
- set active-once mode to recv tcp data
- changed msgpack options
- deleted pending request on timeout
- reset worker state on disconnection

### Misc

- moved get_error function to tnt_proto module
- updated README

## [1.0.1] - 2025-10-13

### Added

- export types: `client/0`, `options/0`, `space_id/0`, `params/0`, `key/0`, `tnt_tuple/0`, `operation/0`
- type `operation/0` as `nonempty_list`
- more examples in the README

### Fixed

- specs for `upsert/4`, `update/4`, `update/5`, `upsert_sync/4`, `update_sync/4`, `update_sync/5`, `eval_sync/2`, `eval_sync/3`, `wait/2` from the `tnt` module.
- specs for `request_upsert/3`, `request_update/4`
- type of field `answer` of record `tnt_reply` from `ok | tnt_proto:tnt_tuple()` to `any()`
- msgpack options for message body unpacking
- type `key/0` in the `tnt_proto` module

## [1.0.0] - 2025-10-07

### Added

- Basic Tarantool client functionality
- Connection authentication
- Full CRUD support
- Stored procedure calls (`eval`/`call`)
- Server ping capability
- Both synchronous and asynchronous APIs
- Configurable reconnection logic
- Request queue management
- MessagePack serialization via the `msgpack` library

[1.0.2]: https://github.com/yak-zuk-zop/tnt/compare/v1.0.1...v1.0.2
[1.0.1]: https://github.com/yak-zuk-zop/tnt/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/yak-zuk-zop/tnt/releases/tag/v1.0.0
