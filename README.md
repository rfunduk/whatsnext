<img src="./assets/whatsnext.png" alt="WhatsNext!?" width=567 />

An interactive choose-your-own-adventure story builder with PDF export.

Create stories made of chapters connected by choices, then export them as printable PDFs.


## Features

- Build branching narratives with interconnected chapters and choices
- Flowchart view of story structure
- Chapters can have images before and/or after the text
- Export as full-size A4 PDF or saddle-stitch A5 booklet


## Setup

```
bin/setup                   # download dependencies
bin/build [debug|release]   # compile
```

Requires [Odin](https://odin-lang.org/) and `zlib`, `libpng`, `libjpeg`, and regular C toolchain for vendored dependencies.


## Usage

Serves at [0.0.0.0:8020](http://0.0.0.0:8020)

```
build/debug/whatsnext
build/release/whatsnext path/to/wn.db   # optionally specify db location
```

Or docker:

```
docker build -t whatsnext .
docker run -p 8020:8020 -v ./data:/app/data whatsnext
```

For development with auto-reload:

```
bin/watch
```
