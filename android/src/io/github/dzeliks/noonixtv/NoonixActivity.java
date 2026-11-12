package io.github.dzeliks.noonixtv;

import android.Manifest;
import android.content.Intent;
import android.content.pm.ApplicationInfo;
import android.content.pm.PackageManager;
import android.database.Cursor;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.graphics.Matrix;
import android.graphics.PixelFormat;
import android.media.ExifInterface;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.provider.OpenableColumns;
import android.system.Os;
import android.view.Display;
import android.view.WindowManager;
import android.view.Gravity;
import android.view.Surface;
import android.view.InputDevice;
import android.view.KeyCharacterMap;
import android.view.KeyEvent;
import android.view.SurfaceHolder;
import android.view.SurfaceView;
import android.view.View;
import android.view.ViewGroup;
import android.view.WindowInsets;
import android.view.WindowInsetsController;
import android.widget.FrameLayout;

import java.io.File;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.util.Arrays;

import org.qtproject.qt.android.bindings.QtActivity;

// qt hands gamepad buttons over as unknown keys: they go to the app's own pad handling instead
// (src/input.cpp), by position like sdl names them on the desktop
public class NoonixActivity extends QtActivity {
    private static native void padButton(String name, boolean down, String kind);

    // the video: its own surface view under qt's (qt's is a media overlay above it, see main.cpp),
    // drawn by src/videosurface_android.cpp. 10 bits per colour, pq / bt.2020 while hdr plays
    private native void videoSurface(Surface surface, int w, int h);
    private SurfaceView video;
    private volatile Surface videoNow;

    // the surface for the decoder (hdr straight to the panel), null while there is none
    public Surface videoSurfaceObject() {
        return videoNow;
    }

    // the decoder's picture fills the view: the view takes the video's shape then (w, h: display
    // size), 0 = the whole screen (mpv letterboxes itself)
    public void videoFit(final int w, final int h) {
        runOnUiThread(() -> {
            if (video == null)
                return;
            View content = findViewById(android.R.id.content);
            int cw = content.getWidth(), ch = content.getHeight();
            FrameLayout.LayoutParams lp;
            if (w <= 0 || h <= 0 || cw <= 0 || ch <= 0) {
                lp = new FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT);
            } else {
                double s = Math.min((double) cw / w, (double) ch / h);
                lp = new FrameLayout.LayoutParams((int) Math.round(w * s), (int) Math.round(h * s), Gravity.CENTER);
            }
            video.setLayoutParams(lp);
        });
    }

    public void videoShown(final boolean on) {
        runOnUiThread(() -> {
            if (video == null) {
                if (!on)
                    return;
                video = new SurfaceView(this);
                video.getHolder().setFormat(PixelFormat.RGBA_1010102);
                video.getHolder().addCallback(new SurfaceHolder.Callback() {
                    @Override public void surfaceCreated(SurfaceHolder h) {}
                    @Override public void surfaceChanged(SurfaceHolder h, int format, int w, int ht) {
                        videoNow = h.getSurface();
                        videoSurface(h.getSurface(), w, ht);
                    }
                    @Override public void surfaceDestroyed(SurfaceHolder h) {
                        videoNow = null;
                        videoSurface(null, 0, 0);
                    }
                });
                ViewGroup content = findViewById(android.R.id.content);
                content.addView(video, 0, new FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));
            }
            video.setVisibility(on ? View.VISIBLE : View.GONE);
            videoUp = on;
            applyBars();
        });
    }

    // the panel's hdr10 peak in nits, 0 without hdr10
    public float hdrPeak() {
        try {
            Display d = getWindowManager().getDefaultDisplay();
            Display.HdrCapabilities caps = d.getHdrCapabilities();
            if (caps == null)
                return 0;
            for (int t : caps.getSupportedHdrTypes())
                if (t == Display.HdrCapabilities.HDR_TYPE_HDR10) {
                    float peak = caps.getDesiredMaxLuminance();
                    // some panels report nothing: a common phone peak then
                    return peak > 50 ? peak : 500;
                }
        } catch (Exception ignored) {
        }
        return 0;
    }

    // refresh rate matching (android tv): "current,id:hz,id:hz" for the modes at the current size
    public String displayModes() {
        try {
            Display d = getWindowManager().getDefaultDisplay();
            Display.Mode cur = d.getMode();
            StringBuilder b = new StringBuilder().append(cur.getModeId());
            for (Display.Mode m : d.getSupportedModes())
                if (m.getPhysicalWidth() == cur.getPhysicalWidth() && m.getPhysicalHeight() == cur.getPhysicalHeight())
                    b.append(',').append(m.getModeId()).append(':').append(m.getRefreshRate());
            return b.toString();
        } catch (Exception e) {
            return "";
        }
    }

    // the window asks for that mode (0: the system's own again); the tv switches by itself
    public void displayMode(final int id) {
        runOnUiThread(() -> {
            WindowManager.LayoutParams p = getWindow().getAttributes();
            if (p.preferredDisplayModeId == id)
                return;
            p.preferredDisplayModeId = id;
            getWindow().setAttributes(p);
        });
    }

    // the library's folders: videos on shared storage (android 13 asks per media type)
    public void askMedia() {
        final String p = Build.VERSION.SDK_INT >= 33 ? Manifest.permission.READ_MEDIA_VIDEO : Manifest.permission.READ_EXTERNAL_STORAGE;
        if (checkSelfPermission(p) != PackageManager.PERMISSION_GRANTED)
            runOnUiThread(() -> requestPermissions(new String[] { p }, 1));
    }

    // a profile picture from the phone's gallery: shrunk, turned upright and saved into the
    // avatars folder (the app's own, nothing else can put files there). "" when none came back
    private static native void picturePicked(String path);
    private static final int PICK_PICTURE = 7;
    private String pickDir;

    private Intent pictureIntent() {
        return new Intent(Intent.ACTION_GET_CONTENT).setType("image/*").addCategory(Intent.CATEGORY_OPENABLE);
    }

    // back at the top on a phone: away like any app, nothing lost
    public void toBackground() {
        runOnUiThread(() -> moveTaskToBack(true));
    }

    public boolean canPickPicture() {
        return pictureIntent().resolveActivity(getPackageManager()) != null;
    }

    public void pickPicture(final String dir) {
        runOnUiThread(() -> {
            pickDir = dir;
            try {
                startActivityForResult(pictureIntent(), PICK_PICTURE);
            } catch (Exception e) {
                picturePicked("");
            }
        });
    }

    // a file from the phone (an extension, subtitles): android hands out only a stream, so it's copied
    // into the app's cache. "" = none picked, "!big" = over max bytes, "!fail" = couldn't be read
    private static native void filePicked(String tag, String path);
    private static final int PICK_FILE = 8;
    private String pickTag = "";
    private long pickMax;

    private Intent fileIntent() {
        return new Intent(Intent.ACTION_OPEN_DOCUMENT).setType("*/*").addCategory(Intent.CATEGORY_OPENABLE);
    }

    public boolean canPickFile() {
        return fileIntent().resolveActivity(getPackageManager()) != null;
    }

    public void pickFile(final String tag, final long max) {
        runOnUiThread(() -> {
            pickTag = tag;
            pickMax = max;
            try {
                startActivityForResult(fileIntent(), PICK_FILE);
            } catch (Exception e) {
                filePicked(tag, "");
            }
        });
    }

    private String copyPicked(Uri uri, String tag, long max) {
        String name = null;
        try (Cursor c = getContentResolver().query(uri, new String[] { OpenableColumns.DISPLAY_NAME }, null, null, null)) {
            if (c != null && c.moveToFirst())
                name = c.getString(0);
        } catch (Exception ignored) {
        }
        // the name is kept for its extension and the subtitle list: no folders, no hidden files
        name = name == null ? "" : name.replaceAll("[/\\\\:\\x00-\\x1f]", "_").replaceAll("^\\.+", "");
        if (name.isEmpty())
            name = "file";
        if (name.length() > 120)
            name = name.substring(name.length() - 120);
        // one folder per kind, only its latest pick kept
        File dir = new File(new File(getCacheDir(), "picked"), tag.replaceAll("[^a-z]", ""));
        File[] old = dir.listFiles();
        if (old != null)
            for (File f : old)
                f.delete();
        dir.mkdirs();
        File out = new File(dir, name);
        String err = null;
        try (InputStream in = getContentResolver().openInputStream(uri); FileOutputStream f = new FileOutputStream(out)) {
            if (in == null)
                err = "!fail";
            byte[] b = new byte[65536];
            long n = 0;
            for (int r; err == null && (r = in.read(b)) > 0; ) {
                n += r;
                if (n > max)
                    err = "!big";
                else
                    f.write(b, 0, r);
            }
        } catch (Exception e) {
            err = "!fail";
        }
        if (err == null)
            return out.getAbsolutePath();
        out.delete();
        return err;
    }

    @Override
    protected void onActivityResult(int request, int result, Intent data) {
        if (request == PICK_FILE) {
            final String tag = pickTag;
            final long max = pickMax;
            final Uri uri = result == RESULT_OK && data != null ? data.getData() : null;
            if (uri == null)
                filePicked(tag, "");
            else
                new Thread(() -> filePicked(tag, copyPicked(uri, tag, max))).start();
            return;
        }
        if (request != PICK_PICTURE) {
            super.onActivityResult(request, result, data);
            return;
        }
        final Uri uri = result == RESULT_OK && data != null ? data.getData() : null;
        if (uri == null) {
            picturePicked("");
            return;
        }
        new Thread(() -> picturePicked(savePicture(uri))).start();
    }

    private String savePicture(Uri uri) {
        try {
            BitmapFactory.Options o = new BitmapFactory.Options();
            o.inJustDecodeBounds = true;
            try (InputStream in = getContentResolver().openInputStream(uri)) {
                BitmapFactory.decodeStream(in, null, o);
            }
            if (o.outWidth <= 0 || o.outHeight <= 0)
                return "";
            // about 512 px on the short side is plenty for a round avatar
            int sample = 1;
            while (Math.min(o.outWidth, o.outHeight) / (sample * 2) >= 512)
                sample *= 2;
            BitmapFactory.Options d = new BitmapFactory.Options();
            d.inSampleSize = sample;
            Bitmap b;
            try (InputStream in = getContentResolver().openInputStream(uri)) {
                b = BitmapFactory.decodeStream(in, null, d);
            }
            if (b == null)
                return "";
            int turn = 0;
            try (InputStream in = getContentResolver().openInputStream(uri)) {
                switch (new ExifInterface(in).getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL)) {
                    case ExifInterface.ORIENTATION_ROTATE_90: turn = 90; break;
                    case ExifInterface.ORIENTATION_ROTATE_180: turn = 180; break;
                    case ExifInterface.ORIENTATION_ROTATE_270: turn = 270; break;
                }
            } catch (Exception ignored) {
            }
            if (turn != 0) {
                Matrix m = new Matrix();
                m.postRotate(turn);
                b = Bitmap.createBitmap(b, 0, 0, b.getWidth(), b.getHeight(), m, true);
            }
            File dir = new File(pickDir);
            dir.mkdirs();
            boolean alpha = b.hasAlpha();
            File out = new File(dir, "picture-" + System.currentTimeMillis() + (alpha ? ".png" : ".jpg"));
            try (FileOutputStream f = new FileOutputStream(out)) {
                b.compress(alpha ? Bitmap.CompressFormat.PNG : Bitmap.CompressFormat.JPEG, 90, f);
            }
            return out.getAbsolutePath();
        } catch (Exception e) {
            return "";
        }
    }

    private static String name(int code) {
        switch (code) {
            case KeyEvent.KEYCODE_BUTTON_A: return "south";
            case KeyEvent.KEYCODE_BUTTON_B: return "east";
            case KeyEvent.KEYCODE_BUTTON_X: return "west";
            case KeyEvent.KEYCODE_BUTTON_Y: return "north";
            case KeyEvent.KEYCODE_BUTTON_L1: return "lb";
            case KeyEvent.KEYCODE_BUTTON_R1: return "rb";
            case KeyEvent.KEYCODE_BUTTON_L2: return "lt";
            case KeyEvent.KEYCODE_BUTTON_R2: return "rt";
            case KeyEvent.KEYCODE_BUTTON_THUMBL: return "ls";
            case KeyEvent.KEYCODE_BUTTON_THUMBR: return "rs";
            case KeyEvent.KEYCODE_BUTTON_START: return "start";
            case KeyEvent.KEYCODE_BUTTON_SELECT: return "back";
            case KeyEvent.KEYCODE_BUTTON_MODE: return "guide";
            default: return null;
        }
    }

    private static String kind(InputDevice d) {
        if (d == null)
            return "generic";
        switch (d.getVendorId()) {
            case 0x054c: return "playstation";
            case 0x045e: return "xbox";
            case 0x057e: return "nintendo";
            default: return "generic";
        }
    }

    // tests: am start ... --es noonixEnv "NOONIX_HIDE=1,2 NOONIX_MUTE=1". qt takes no launch arguments
    // in a release build, and there only these harmless few are let in (a debuggable build takes any).
    // any app can send this extra: nothing here may reach mpv's options or write a file
    private static final String[] TEST_ENV = {"NOONIX_HIDE", "NOONIX_MUTE", "NOONIX_KEYLOG", "NOONIX_PHONE", "NOONIX_SCALE", "NOONIX_GRIDW", "QT_LOGGING_RULES"};

    @Override
    public void onCreate(Bundle state) {
        String env = getIntent() != null ? getIntent().getStringExtra("noonixEnv") : null;
        if (env != null) {
            boolean debuggable = (getApplicationInfo().flags & ApplicationInfo.FLAG_DEBUGGABLE) != 0;
            for (String pair : env.trim().split("\\s+")) {
                int eq = pair.indexOf('=');
                if (eq <= 0)
                    continue;
                String name = pair.substring(0, eq);
                if (!debuggable && !Arrays.asList(TEST_ENV).contains(name))
                    continue;
                try {
                    Os.setenv(name, pair.substring(eq + 1), true);
                } catch (Exception ignored) {
                }
            }
        }
        super.onCreate(state);
        // qt hides the bars again on its own (full screen): put the gesture line back after it
        getWindow().getDecorView().getViewTreeObserver().addOnGlobalLayoutListener(() -> {
            if (!videoUp)
                applyBars();
        });
    }

    // qt's full screen hides every bar: with gesture navigation the first edge swipe then only
    // brings them out and back needs a second one. outside the player the gesture line stays
    // (drawn over, see-through) so one swipe goes back
    private volatile boolean videoUp = false;
    private boolean gestureNav() {
        return android.provider.Settings.Secure.getInt(getContentResolver(), "navigation_mode", 0) == 2;
    }
    private void applyBars() {
        if (Build.VERSION.SDK_INT < 30 || !gestureNav())
            return;
        WindowInsetsController c = getWindow().getInsetsController();
        WindowInsets in = getWindow().getDecorView().getRootWindowInsets();
        if (c == null || in == null)
            return;
        getWindow().setNavigationBarColor(0);
        getWindow().setNavigationBarContrastEnforced(false);
        if (videoUp) {
            if (in.isVisible(WindowInsets.Type.navigationBars()))
                c.hide(WindowInsets.Type.systemBars());
        } else if (!in.isVisible(WindowInsets.Type.navigationBars())) {
            c.show(WindowInsets.Type.navigationBars());
        }
    }

    @Override
    public void onWindowFocusChanged(boolean focus) {
        super.onWindowFocusChanged(focus);
        if (focus)
            applyBars();
    }

    // the last key came from no real device: the gesture or nav bar back, the on-screen keyboard.
    // those leave touch mode alone (src/input.cpp)
    private static volatile boolean lastKeyVirtual = false;
    public static boolean lastKeyVirtual() { return lastKeyVirtual; }

    @Override
    public boolean dispatchKeyEvent(KeyEvent e) {
        lastKeyVirtual = e.getDeviceId() == KeyCharacterMap.VIRTUAL_KEYBOARD;
        String n = name(e.getKeyCode());
        if (n == null)
            return super.dispatchKeyEvent(e);
        if (e.getRepeatCount() == 0 && e.getAction() != KeyEvent.ACTION_MULTIPLE) {
            try {
                padButton(n, e.getAction() == KeyEvent.ACTION_DOWN, kind(e.getDevice()));
            } catch (UnsatisfiedLinkError notYet) {
                // the app's library isn't up yet
            }
        }
        return true;
    }
}
