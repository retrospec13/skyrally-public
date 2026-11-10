# Music v3 SoundFont and synth (sequenced cues)

The v3 cues (`tools/audio/compose_v3.py`) are rendered from note data through a General MIDI SoundFont. The SoundFont
file is large (32 MB), so it is NOT in the repo. The generator downloads it into its cache folder (`--cache DIR`, or
`$SKYRALLY_MUSIC_CACHE`, default `~/.cache/skyrally_music_v3`), checks the sha256 below, and refuses a mismatch.

## SoundFont: GeneralUser GS v2.0.3 (S. Christian Collins)
- Source: https://github.com/mrbumpy409/GeneralUser-GS (pinned commit `684543d5e5efaef08d02be50dcda8d552478fa60`, 2026-02-23)
- Download URL used by the generator:
  https://raw.githubusercontent.com/mrbumpy409/GeneralUser-GS/684543d5e5efaef08d02be50dcda8d552478fa60/GeneralUser-GS.sf2
- File: `GeneralUser-GS.sf2`, 32,319,396 bytes
- sha256: `9575028c7a1f589f5770fccc8cff2734566af40cd26ed836944e9a5152688cfe`
- Licence file: `documentation/LICENSE.txt` at the same commit, sha256 `7b32efefdf95ce38a043799f0659853ddc00fbaa14d8c50f0aca16b9b8b405be`
- Why this one: its licence allows commercial use of music made with it ("without restriction for your own music creation,
  private or commercial"). What ships in the game is the rendered OGG audio, not the SoundFont.
- Caveats for the owner: (1) the author says some samples came from other free banks and he "cannot be 100% sure where all
  of the samples originated", though none came from commercial packages and he has had no complaint since 2000.
  (2) He asks websites not to link directly to his download files; the generator only fetches the pinned file for a local
  build and nothing links to it publicly.

Licence text (verbatim):

```
*** GeneralUser GS v2.0.3 ***
***      License v2.0     ***

** License of the complete work **
You may use GeneralUser GS without restriction for your own music creation,
private or commercial. This SoundFont bank is provided to the community free of
charge. Please feel free to use it in your software projects, and to modify the
SoundFont bank or its packaging to suit your needs.

** License of contained samples **
GeneralUser GS inherits the usage rights of the samples contained within, all of
which allow full use in music production, including the ability to make profit
from musical recordings created with GeneralUser GS.

Many of the samples are original, but some were taken from other banks freely
(and legally) available on the Internet from various SoundFont websites. Because
GeneralUser GS originated as a personal project with no intention for
publication, I cannot be 100% sure where all of the samples originated, although
I do know that none of them came from commercially published SoundFont packages
or sample CDs. Regardless, many "free" SoundFonts available on the web may
indeed contain samples of questionable origin. My understanding of the
copyrights of all samples is only as good as the information provided by the
original sources. If you become aware of any restricted samples being used in
GeneralUser GS, please let me know so I can replace them.

This uncertainty may concern you if you intend to use GeneralUser GS in a
commercial software product. That being said, I have never received any
complaint regarding sample ownership since I published the original GeneralUser
GS back in 2000, and as far as I am aware, neither have any of the companies
creating commercial software products using GeneralUser GS.

** More info **
If you plan to feature GeneralUser GS on your own website, please do not link
directly to my download files. Either link to my website, or provide your own
local copy instead.

I hope you enjoy GeneralUser GS! This SoundFont bank is the product of many
years of hard work.

You can find updates to GeneralUser GS and more of my virtual instruments at:
http://www.schristiancollins.com

I can be reached via the contact page on my website here:
https://www.schristiancollins.com/contact

Thank you!
-~Chris
```

## Synth: TinySoundFont (Bernhard Schelling), MIT licence
- Taken from the PyPI sdist `tinysoundfont-0.3.7.tar.gz`
  (https://files.pythonhosted.org/packages/0d/c9/96ef50b61a0c39fb7dbafff61ee759e0eb60e87f98eb04860579672127c8/tinysoundfont-0.3.7.tar.gz),
  sha256 `13b560f35469303064d7b597c1584ec35f18193fd915c502c29fcba90ac11d31`.
- Only `src/_tinysoundfont/tsf/tsf.h` is extracted (sha256 `81ebac129d742faf8ee6179977f3c19fde93c31e153a3ac4951051203a193c75`)
  and compiled with the system C compiler into `libtsf.so`, loaded with ctypes. (The PyPI wheel has no aarch64 build and
  its source build needs Python headers, which the lane host lacks.)

```
Copyright (C) 2017-2023 Bernhard Schelling (Based on SFZero, Copyright (C) 2012 Steve Folta, https://github.com/stevefolta/SFZero)

Permission is hereby granted, free of charge, to any person obtaining a copy of
this software and associated documentation files (the "Software"), to deal in
the Software without restriction, including without limitation the rights to
use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies
of the Software, and to permit persons to whom the Software is furnished to do
so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## Rebuild
```
python3 -m venv /path/musicvenv && /path/musicvenv/bin/pip install mido numpy scipy soundfile pyloudnorm
/path/musicvenv/bin/python tools/audio/compose_v3.py --cache /path/cache            # all cues -> assets/audio/music_v3
/path/musicvenv/bin/python tools/audio/compose_v3.py --cache /path/cache music_hub  # one cue
```
Renders are deterministic (fixed humanisation seed); the Vorbis stream serial differs per run, the decoded audio does not.
