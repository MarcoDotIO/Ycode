#!/usr/bin/env python3
"""Saves the whole X display ($DISPLAY) as a PNG, with every window on it (the
input method's candidate window too), and prints the top-level windows'
geometry, so a test can check where the candidate window is.

Usage: screen-x11.py <png>
"""
import os
import subprocess
import sys

from PIL import ImageGrab

ImageGrab.grab(xdisplay=os.environ["DISPLAY"]).save(sys.argv[1])
tree = subprocess.run(["xwininfo", "-root", "-children"], capture_output=True, text=True).stdout
for line in tree.splitlines():
    line = line.strip()
    if line.startswith("0x") and "+" in line:
        print("window:", line, flush=True)
