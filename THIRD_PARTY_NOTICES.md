# Third-party notices

Elga Camera uses the following third-party software.

## odin-imgui and Dear ImGui

The repository vendors generated Odin bindings and a Windows static library
from [odin-imgui](https://github.com/Capati/odin-imgui). The library includes
[Dear ImGui](https://github.com/ocornut/imgui). Both are distributed under MIT
license terms. The vendored license text is available at
[`vendor/odin-imgui/LICENSE`](vendor/odin-imgui/LICENSE).

## miniaudio

Audio capture and playback use [miniaudio](https://miniaud.io/) through Odin's
vendor package. Miniaudio is available under its public-domain dedication or
the MIT No Attribution license, at the recipient's option.

## libcurl

Nintendo Switch 2 wake requests use [libcurl](https://curl.se/libcurl/)
through Odin's vendor package. Libcurl is distributed under the following
license:

Copyright (c) 1996 - 2025, Daniel Stenberg, daniel@haxx.se, and many
contributors, see the THANKS file.

All rights reserved.

Permission to use, copy, modify, and distribute this software for any purpose
with or without fee is hereby granted, provided that the above copyright
notice and this permission notice appear in all copies.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT OF THIRD PARTY RIGHTS. IN
NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM,
DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR
OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE
OR OTHER DEALINGS IN THE SOFTWARE.

Except as contained in this notice, the name of a copyright holder shall not
be used in advertising or otherwise to promote the sale, use or other dealings
in this Software without prior written authorization of the copyright holder.

## stb_image_write

PNG screenshots use [stb_image_write](https://github.com/nothings/stb)
through Odin's vendor package, under its MIT license:

Copyright (c) 2017 Sean Barrett

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.

## Platform APIs

Media Foundation, Direct3D 11, DXGI, WASAPI, and Win32 are Windows platform
APIs supplied by Microsoft and are not vendored in this repository.

Third-party names and trademarks belong to their respective owners. This file
is informational and does not grant a license to Elga Camera itself.
