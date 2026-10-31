package io.github.dzeliks.noonixtv;

import android.view.InputDevice;
import android.view.KeyEvent;

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
