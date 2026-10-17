#!/usr/bin/env python3
"""Produce the bundle Info.plist for the Linux build.

Xcode expands build settings, compiles LaunchScreen.storyboard and writes
the icon entries from the asset catalog. Without ibtool and actool the
launch screen comes from UILaunchScreen and the icons ship as loose PNGs.
"""
import argparse
import plistlib

parser = argparse.ArgumentParser()
parser.add_argument('--source', required=True)
parser.add_argument('--output', required=True)
parser.add_argument('--executable', required=True)
parser.add_argument('--min-os', required=True)
parser.add_argument('--sdk-version', required=True)
parser.add_argument('--build', default=None)
args = parser.parse_args()

with open(args.source, 'rb') as f:
    info = plistlib.load(f)

info['CFBundleExecutable'] = args.executable
if args.build:
    info['CFBundleVersion'] = args.build
info['MinimumOSVersion'] = args.min_os
info['UIDeviceFamily'] = [1, 2]
info['CFBundleSupportedPlatforms'] = ['iPhoneOS']
info['DTPlatformName'] = 'iphoneos'
info['DTPlatformVersion'] = args.sdk_version
info['DTSDKName'] = 'iphoneos' + args.sdk_version
info.pop('UILaunchStoryboardName', None)
info['UILaunchScreen'] = {'UIColorName': ''}
info['CFBundleIcons'] = {'CFBundlePrimaryIcon': {
    'CFBundleIconFiles': ['AppIcon-20', 'AppIcon-29', 'AppIcon-40', 'AppIcon-60'],
    'CFBundleIconName': 'AppIcon'}}
info['CFBundleIcons~ipad'] = {'CFBundlePrimaryIcon': {
    'CFBundleIconFiles': ['AppIcon-20', 'AppIcon-29', 'AppIcon-40', 'AppIcon-76',
                          'AppIcon-83.5'],
    'CFBundleIconName': 'AppIcon'}}

with open(args.output, 'wb') as f:
    plistlib.dump(info, f)
