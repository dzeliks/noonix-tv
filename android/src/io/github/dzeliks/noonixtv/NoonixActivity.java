package io.github.dzeliks.noonixtv;

import android.content.pm.ApplicationInfo;
import android.os.Bundle;
import android.system.Os;
import android.view.InputDevice;
import android.view.KeyEvent;

import java.util.Arrays;

import org.qtproject.qt.android.bindings.QtActivity;

// qt hands gamepad buttons over as unknown keys: they go to the app's own pad handling instead
// (src/input.cpp), by position like sdl names them on the desktop
public class NoonixActivity extends QtActivity {
    private static native void padButton(String name, boolean down, String kind);

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
    // in a release build, and there only these harmless few are let in (a debuggable build takes any)
    private static final String[] TEST_ENV = {"NOONIX_HIDE", "NOONIX_MUTE", "NOONIX_KEYLOG", "QT_LOGGING_RULES"};

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
    }

    @Override
    public boolean dispatchKeyEvent(KeyEvent e) {
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
