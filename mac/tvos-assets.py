#!/usr/bin/env python3
# apple tv's "app icon & top shelf image" brand assets in an asset catalog, from Resources/tvos
# (tvos-icons.sh makes those). usage: tvos-assets.py <Resources/tvos> <Assets.xcassets>
import json, os, shutil, sys

src, cat = sys.argv[1], sys.argv[2]
INFO = {"version": 1, "author": "xcode"}


def put(path, data):
    os.makedirs(path, exist_ok=True)
    with open(os.path.join(path, "Contents.json"), "w") as f:
        json.dump({**data, "info": INFO}, f)


def imageset(path, files):
    os.makedirs(path, exist_ok=True)
    images = []
    for scale, name in files:
        shutil.copy(os.path.join(src, name), os.path.join(path, name))
        images.append({"filename": name, "idiom": "tv", "scale": scale})
    put(path, {"images": images})


def stack(path, front, back):
    put(path, {"layers": [{"filename": "Front.imagestacklayer"}, {"filename": "Back.imagestacklayer"}]})
    for layer, files in (("Front", front), ("Back", back)):
        put(os.path.join(path, f"{layer}.imagestacklayer"), {})
        imageset(os.path.join(path, f"{layer}.imagestacklayer", "Content.imageset"), files)


brand = os.path.join(cat, "App Icon & Top Shelf Image.brandassets")
put(brand, {"assets": [
    {"filename": "App Icon.imagestack", "idiom": "tv", "role": "primary-app-icon", "size": "400x240"},
    {"filename": "App Icon - App Store.imagestack", "idiom": "tv", "role": "primary-app-icon", "size": "1280x768"},
    {"filename": "Top Shelf Image Wide.imageset", "idiom": "tv", "role": "top-shelf-image-wide", "size": "2320x720"},
    {"filename": "Top Shelf Image.imageset", "idiom": "tv", "role": "top-shelf-image", "size": "1920x720"},
]})
stack(os.path.join(brand, "App Icon.imagestack"),
      [("1x", "icon-front.png"), ("2x", "icon@2x-front.png")], [("1x", "icon-back.png"), ("2x", "icon@2x-back.png")])
stack(os.path.join(brand, "App Icon - App Store.imagestack"), [("1x", "store-front.png")], [("1x", "store-back.png")])
imageset(os.path.join(brand, "Top Shelf Image.imageset"), [("1x", "shelf.png"), ("2x", "shelf@2x.png")])
imageset(os.path.join(brand, "Top Shelf Image Wide.imageset"), [("1x", "shelf-wide.png"), ("2x", "shelf-wide@2x.png")])
# the about page draws the icon itself (a layered icon isn't an image the app can load)
imageset(os.path.join(cat, "TVIconBack.imageset"), [("2x", "icon@2x-back.png")])
imageset(os.path.join(cat, "TVIconFront.imageset"), [("2x", "icon@2x-front.png")])
# the launch image: what the icon zooms into when the app opens (tvos has no launch colour)
launch = os.path.join(cat, "LaunchImage.launchimage")
os.makedirs(launch, exist_ok=True)
images = []
for scale, name in (("1x", "launch.png"), ("2x", "launch@2x.png")):
    shutil.copy(os.path.join(src, name), os.path.join(launch, name))
    images.append({"orientation": "landscape", "idiom": "tv", "extent": "full-screen",
                   "minimum-system-version": "11.0", "filename": name, "scale": scale})
put(launch, {"images": images})
