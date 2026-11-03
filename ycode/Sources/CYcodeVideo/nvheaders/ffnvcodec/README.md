# Vendored NVIDIA codec headers

`nvEncodeAPI.h`, `dynlink_cuda.h`, `dynlink_cuviddec.h` and `dynlink_nvcuvid.h`
from FFmpeg's nv-codec-headers, tag `n12.2.72.0` (commit
`c69278340ab1d5559c7d7bf0edf615dc33ddbba7`, 2024-03-31; Video Codec SDK 12.x,
driver 550.54.14 or newer), fetched with
`git clone --branch n12.2.72.0 https://github.com/FFmpeg/nv-codec-headers` on
2026-10-31, copied unmodified. Each file carries its own MIT permission notice
("This copyright notice applies to this header file only"). They describe the
interfaces of the NVIDIA driver's `libnvidia-encode`, `libnvcuvid` and `libcuda`;
CYcodeVideo opens those libraries at run time (nothing is linked), so the
package builds and runs where they are absent.
