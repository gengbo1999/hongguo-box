//! 红果 7.4.3.32 请求签名（MetaSec v5）：算法本体是 JS/APK 1:1 移植，禁改写法。

#![allow(
    clippy::manual_rotate,
    clippy::needless_range_loop,
    clippy::unnecessary_cast,
    clippy::too_many_arguments,
    non_snake_case
)]

pub mod aes_v3;
pub mod constants;
pub mod device;
pub mod helios;
pub mod medusa;
pub mod medusa_v5;
pub mod metasec;
pub mod primitives;
pub mod protobuf;
pub mod xargus;
pub mod xgorgon;

pub use device::{
    APP_ID, APP_VERSION_CODE, APP_VERSION_CODE_STR, APP_VERSION_NAME, CHANNEL_ID,
    RegisterFingerprint, anonymous_cookie, device_proto, fingerprint_for_cdid, fresh_cdid,
    video_ua,
};
pub use helios::helios;
pub use medusa::build_medusa;
pub use primitives::md5_hex_upper;