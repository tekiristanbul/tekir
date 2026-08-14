/// How large a photo is allowed to be when it leaves the device.
///
/// The picker hands over the camera's original: a current phone produces
/// something like 2643x4698 at around 2 MB. Nothing in the product ever
/// shows a cat photo larger than the screen, so those pixels are paid for
/// three times over and used once — the upload spends them on a cellular
/// link, the backend spends them decoding, re-orienting and re-encoding
/// inside the user's own request, and every client decodes them again for a
/// 132pt avatar (see decode_budget.dart).
///
/// 1600px on the long edge at quality 85 lands around 300 KB, which is
/// still more detail than the full-screen viewer can show on any current
/// device. The cost is paid once, on the device, before the request starts.
const double uploadMaxDimension = 1600;

/// JPEG quality for the resized upload. 85 is the usual point where further
/// reduction starts showing on flat areas like sky or fur.
const int uploadImageQuality = 85;
