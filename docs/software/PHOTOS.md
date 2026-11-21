# Photo viewer (`PHOTO.PLC`)

Date: 2026-11-21

`sdcard/PHOTO.PLC` (`src/scripts/photo.masm`) shows the pictures in the
card's `PHOTOS` folder: photographs at 160 x 240 pixels in 256 colors, on a
screen of 160-read rows with 2x line repeat.  That is a rev B video mode
([HIRES.md](../video/HIRES.md)); on a rev A board the same files show 80
pixels across.

![The five pictures on the card, as placard_sim.py draws the rev B screen](photos_demo.png)

The screens above are the emulator's (`placard_sim.py`, rev B) after the
viewer loaded each file from a card image.  A pixel is 4 screen pixels wide
and 2 tall.

## Keys

| Key | Does |
|---|---|
| H | at the start: 160 across (rev B board).  Any other key: 80 across (any board).  While a picture shows: changes between the two |
| Space, Right, Enter | the next picture (after the last, the first) |
| Left, Backspace | the picture before |
| S | slide show on or off: the next picture by itself about every 9 seconds |
| Esc | back to the DOS, or to Pinboard |

The program asks at the start because a rev A board shows a 160-read row
as a blank line: the screen would stay black.  With 80 across (mode byte
x07, a normal 8 bpp row with 2x repeat) the board reads the odd byte
columns of the same picture, so one file serves both boards.

## From Pinboard

In [Pinboard](PINBOARD.md)'s Files card, Enter on a `.PIC` file runs the
viewer on that picture.  The pictures are then those of the file's folder,
which need not be `PHOTOS`, and Esc goes back to Pinboard in that folder.
The viewer skips its first screen when it knows the width: Pinboard in a
color mode means a rev B board (160 across), and an answer given once is
kept until power-off.  Pinboard leaves the folder's first cluster, the
picture's number among the folder's `.PIC` files and the mark "V" in the
menu block (x5D19-x5D1F, `placard_menu.asm`); run from the DOS, the viewer
finds no mark and shows the `PHOTOS` folder as before.

## Picture files

Any file in `PHOTOS` whose name ends in `.PIC` is a picture; they show in
the order they are in the folder (255 at most).  A `.PIC` file is the video
RAM x6000-xFFFF as it is, 40,960 bytes (80 sectors), which the viewer reads
straight to the screen with `fs_read`.  A picture takes about 0.6 seconds
and comes in from the left.

    byte column c (0-159), picture row r (0-239), v = 32 + 2r:
    offset in the file = c * 256 + ((v & xFE) | (v >> 8))
    byte = GGG BB RRR (docs/video/COLORS.md, 8-bit color mode)

The 16 bytes of every 256 that the mode never shows are 00.

`src/scripts/gen_photos.py` makes the files from the photographs in
`src/photos/`: it cuts each to 4:3, squeezes it to 160 x 240, and picks the
colors by error diffusion (Floyd-Steinberg in linear light, the nearest
color chosen in Oklab).  The five codes that color decoder revision 08
blends into grays are not used, so a picture is the same on every decoder
revision.  To add a picture, put the photograph in `src/photos/`, add a
line to `PHOTOS` in the script and run it (`--png DIR` also writes each
picture as a PNG).

`src/scripts/test_photo.py` boots a card with the viewer in `placard_sim.py`
as a rev B board and checks the count, every key, both widths, the slide
show, that the video RAM is each file byte for byte, and the message for a
card without the folder.

Not tried on hardware.

## The photographs

| File | Photograph | By | License |
|---|---|---|---|
| `TULIPS.PIC` | [tulips over grape hyacinths](https://www.flickr.com/photos/comunicati/3502685880/) | Michela Simoncini | CC BY 2.0 |
| `SUNFLOWR.PIC` | [sunflowers](https://www.flickr.com/photos/paraflyer/23204123212/) | Tobias Haase | CC BY 2.0 |
| `PURPLE.PIC` | [purple tulips](https://www.flickr.com/photos/jeepersmedia/12916135413/) | Mike Mozart | CC BY 2.0 |
| `TEMPLE.PIC` | [the Tower of Buddhist Incense, Summer Palace, Beijing](https://www.flickr.com/photos/danielbuechele/6061409035/) | Daniel Büchele | CC BY 2.0 |
| `ASTRONAU.PIC` | astronaut Eileen Collins | NASA | public domain |

The three flower photographs are from the TensorFlow flower photos set, the
temple from scikit-learn's sample images and the astronaut from
scikit-image's.  All were cut, resized and reduced to the board's colors
for the card.  [CC BY 2.0](https://creativecommons.org/licenses/by/2.0/).
