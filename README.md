# WhatsNext

An interactive choose-your-own-adventure story builder with PDF export.

Create stories made of chapters connected by choices, then export them as printable PDFs.

## Features

- Build branching narratives with interconnected chapters and choices
- Flowchart view of story structure
- Chapters can have images before and/or after the text
- Export as full-size A4 PDF or saddle-stitch A5 booklet

## Setup

```
bin/setup    # download dependencies
bin/build    # compile
```

Requires [Odin](https://odin-lang.org/) and `zlib`, `libpng`, `libjpeg`, and regular C toolchain for vendored dependencies.

## Usage

```
build/debug/whatsnext
```

Opens a web server at [localhost:8020](http://localhost:8020).

For development with auto-reload:

```
bin/watch
```

## Deployment

```
bin/container build
bin/container run
```
