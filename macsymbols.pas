{*************************************************************************************
  This file is part of Transmission Remote GUI.

  Transmission Remote GUI is free software; you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation; either version 2 of the License, or
  (at your option) any later version.

  Transmission Remote GUI is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  GNU General Public License for more details.

  You should have received a copy of the GNU General Public License
  along with Transmission Remote GUI; if not, write to the Free Software
  Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA  02110-1301  USA
*************************************************************************************}

unit MacSymbols;

{$mode objfpc}{$H+}
{$modeswitch objectivec1}

// Renders macOS system symbols (SF Symbols, macOS 11 and later) into bitmaps.
// The symbols are vector images, so they stay sharp at any size and on Retina displays.
// Also reports changes of the system appearance (light/dark).

interface

uses
  Classes, SysUtils, Graphics;

// Returns a square APixelSize bitmap of the symbol painted with AColor,
// or nil if the system does not provide the symbol.
function CreateSymbolBitmap(const AName: string; APixelSize: integer; AColor: TColor): TBitmap;

type
  TAppearanceChangedEvent = procedure of object;

// AHandler is called in the main thread after the application switched between
// the light and the dark appearance. System colors already have their new values then.
// Pass nil to stop the notifications.
procedure SetAppearanceChangedHandler(AHandler: TAppearanceChangedEvent);

// Replaces the native tooltips of a control. AHandle is the Handle of a TWinControl,
// ARects are in its client coordinates. Only one control can have such tooltips.
procedure SetViewToolTips(AHandle: PtrUInt; const ARects: array of TRect; const ATexts: array of string);

// Sets the native tooltip of a whole control; an empty text removes it.
procedure SetViewToolTip(AHandle: PtrUInt; const AText: string);

implementation

uses
  CocoaAll, Forms;

type
  // These methods are missing from the Cocoa headers shipped with FPC.
  TSymbolMethods = objccategory external (NSObject)
    function imageWithSystemSymbolName_accessibilityDescription(aName: NSString; aDescription: NSString): NSImage;
      message 'imageWithSystemSymbolName:accessibilityDescription:';
    function configurationWithPointSize_weight(aPointSize: double; aWeight: double): id;
      message 'configurationWithPointSize:weight:';
    function imageWithSymbolConfiguration(aConfiguration: id): NSImage;
      message 'imageWithSymbolConfiguration:';
    function effectiveAppearance: id; message 'effectiveAppearance';
    procedure setCurrentAppearance(aAppearance: id); message 'setCurrentAppearance:';
    function initSymbolBitmapRep(aPlanes: Pointer; aWidth, aHeight, aBitsPerSample, aSamplesPerPixel: NSInteger;
      aHasAlpha, aIsPlanar: ObjCBOOL; aColorSpaceName: NSString; aBytesPerRow, aBitsPerPixel: NSInteger): id;
      message 'initWithBitmapDataPlanes:pixelsWide:pixelsHigh:bitsPerSample:samplesPerPixel:hasAlpha:isPlanar:colorSpaceName:bytesPerRow:bitsPerPixel:';
  end;

  TAppearanceObserver = objcclass(NSObject)
    procedure observeValueForKeyPath_ofObject_change_context(keyPath: NSString; object_: id;
      change: NSDictionary; context: pointer); override;
  end;

  TAppearanceNotifier = class
    procedure Notify(Data: PtrInt);
  end;

const
  AppearanceKeyPath = 'effectiveAppearance';

var
  AppearanceObserver: TAppearanceObserver;
  AppearanceNotifier: TAppearanceNotifier;
  AppearanceHandler: TAppearanceChangedEvent;

procedure TAppearanceObserver.observeValueForKeyPath_ofObject_change_context(keyPath: NSString;
  object_: id; change: NSDictionary; context: pointer);
begin
  if (AppearanceNotifier <> nil) and (Application <> nil) then
    // Leave the notification before touching any control.
    Application.QueueAsyncCall(@AppearanceNotifier.Notify, 0);
end;

procedure TAppearanceNotifier.Notify(Data: PtrInt);
var
  AppearanceClass: id;
begin
  // LCL resolves system colors with the current appearance, which does not
  // follow the application appearance outside of drawing.
  AppearanceClass:=id(NSClassFromString(NSSTR('NSAppearance')));
  if (AppearanceClass <> nil) and
     AppearanceClass.respondsToSelector(objcselector('setCurrentAppearance:')) then
    AppearanceClass.setCurrentAppearance(NSApp.effectiveAppearance);
  if Assigned(AppearanceHandler) then
    AppearanceHandler();
end;

procedure SetAppearanceChangedHandler(AHandler: TAppearanceChangedEvent);
begin
  AppearanceHandler:=AHandler;
  if not Assigned(AHandler) then begin
    if AppearanceNotifier <> nil then
      Application.RemoveAsyncCalls(AppearanceNotifier);
    exit;
  end;
  if AppearanceObserver <> nil then
    exit;
  if not NSApp.respondsToSelector(objcselector('effectiveAppearance')) then
    exit;  // macOS before 10.14 has no dark appearance
  AppearanceNotifier:=TAppearanceNotifier.Create;
  AppearanceObserver:=TAppearanceObserver.alloc.init;
  NSApp.addObserver_forKeyPath_options_context(AppearanceObserver, NSSTR(AppearanceKeyPath), 0, nil);
end;

var
  ToolTipTexts: NSMutableArray;  // tooltip owners are not retained by the view

procedure SetViewToolTips(AHandle: PtrUInt; const ARects: array of TRect; const ATexts: array of string);
var
  v: NSView;
  i: integer;
  r: NSRect;
  txt: NSString;
begin
  if AHandle = 0 then
    exit;
  v:=NSView(AHandle);
  v.removeAllToolTips;
  if ToolTipTexts = nil then
    ToolTipTexts:=NSMutableArray.alloc.init
  else
    ToolTipTexts.removeAllObjects;
  for i:=0 to High(ARects) do begin
    if i > High(ATexts) then
      break;
    r.origin.x:=ARects[i].Left;
    r.size.width:=ARects[i].Right - ARects[i].Left;
    r.size.height:=ARects[i].Bottom - ARects[i].Top;
    if v.isFlipped then
      r.origin.y:=ARects[i].Top
    else
      r.origin.y:=v.bounds.size.height - ARects[i].Bottom;
    txt:=NSString.stringWithUTF8String(PChar(ATexts[i]));
    ToolTipTexts.addObject(txt);
    // An NSString owner is shown as the tooltip text.
    v.addToolTipRect_owner_userData(r, txt, nil);
  end;
end;

procedure SetViewToolTip(AHandle: PtrUInt; const AText: string);
begin
  if AHandle = 0 then
    exit;
  if AText = '' then
    NSView(AHandle).setToolTip(nil)
  else
    NSView(AHandle).setToolTip(NSString.stringWithUTF8String(PChar(AText)));
end;

const
  SymbolWeightMedium = 0.23;  // NSFontWeightMedium
  SymbolFill = 0.86;          // part of the bitmap covered by the symbol

function CreateSymbolBitmap(const AName: string; APixelSize: integer; AColor: TColor): TBitmap;
var
  pool: NSAutoreleasePool;
  ImageClass, ConfigClass: id;
  img, sized: NSImage;
  rep: NSBitmapImageRep;
  ctx: NSGraphicsContext;
  data: NSData;
  sz: NSSize;
  dst: NSRect;
  scale: double;
  rgb: TColor;
  ms: TMemoryStream;
  png: TPortableNetworkGraphic;
begin
  Result:=nil;
  if APixelSize < 1 then
    exit;
  pool:=NSAutoreleasePool.alloc.init;
  try
    ImageClass:=id(NSImage.classClass);
    if not ImageClass.respondsToSelector(
         objcselector('imageWithSystemSymbolName:accessibilityDescription:')) then
      exit;
    img:=ImageClass.imageWithSystemSymbolName_accessibilityDescription(
      NSString.stringWithUTF8String(PChar(AName)), nil);
    if img = nil then
      exit;
    ConfigClass:=id(NSClassFromString(NSSTR('NSImageSymbolConfiguration')));
    if ConfigClass <> nil then begin
      sized:=img.imageWithSymbolConfiguration(
        ConfigClass.configurationWithPointSize_weight(APixelSize, SymbolWeightMedium));
      if sized <> nil then
        img:=sized;
    end;
    sz:=img.size;
    if (sz.width <= 0) or (sz.height <= 0) then
      exit;

    rep:=NSBitmapImageRep(NSBitmapImageRep.alloc.initSymbolBitmapRep(
      nil, APixelSize, APixelSize, 8, 4, True, False, NSCalibratedRGBColorSpace, 0, 0));
    if rep = nil then
      exit;
    try
      scale:=APixelSize*SymbolFill/sz.width;
      if APixelSize*SymbolFill/sz.height < scale then
        scale:=APixelSize*SymbolFill/sz.height;
      dst.size.width:=sz.width*scale;
      dst.size.height:=sz.height*scale;
      dst.origin.x:=(APixelSize - dst.size.width)/2;
      dst.origin.y:=(APixelSize - dst.size.height)/2;

      ctx:=NSGraphicsContext.graphicsContextWithBitmapImageRep(rep);
      NSGraphicsContext.classSaveGraphicsState;
      try
        NSGraphicsContext.setCurrentContext(ctx);
        img.drawInRect_fromRect_operation_fraction(dst, NSZeroRect, NSCompositeSourceOver, 1);
        // Symbols are templates: keep their shape and replace the color.
        rgb:=ColorToRGB(AColor);
        NSColor.colorWithCalibratedRed_green_blue_alpha(
          (rgb and $FF)/255, ((rgb shr 8) and $FF)/255, ((rgb shr 16) and $FF)/255, 1).set_;
        NSRectFillUsingOperation(NSMakeRect(0, 0, APixelSize, APixelSize), NSCompositeSourceIn);
        ctx.flushGraphics;
      finally
        NSGraphicsContext.classRestoreGraphicsState;
      end;

      data:=rep.representationUsingType_properties(NSPNGFileType, nil);
      if data = nil then
        exit;
      ms:=TMemoryStream.Create;
      png:=TPortableNetworkGraphic.Create;
      try
        ms.WriteBuffer(data.bytes^, data.length);
        ms.Position:=0;
        png.LoadFromStream(ms);
        Result:=TBitmap.Create;
        try
          Result.Assign(png);
        except
          FreeAndNil(Result);
          raise;
        end;
      finally
        png.Free;
        ms.Free;
      end;
    finally
      rep.release;
    end;
  finally
    pool.release;
  end;
end;

end.
