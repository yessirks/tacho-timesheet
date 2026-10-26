package io.github.yessirks.trukia;

import com.google.androidbrowserhelper.locationdelegation.LocationDelegationExtraCommandHandler;

/** Lets the web app ask Android for GPS (the 📍 buttons) through the app's own location permission. */
public class DelegationService extends com.google.androidbrowserhelper.trusted.DelegationService {
    @Override
    public void onCreate() {
        super.onCreate();
        registerExtraCommandHandler(new LocationDelegationExtraCommandHandler());
    }
}
