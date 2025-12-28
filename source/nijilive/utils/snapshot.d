module nijilive.utils.snapshot;

import nijilive.core.nodes;
import nijilive.core.nodes.composite;
import nijilive.core.puppet;
import nijilive.core.texture;
import inmath;

class Snapshot {
protected:
    Puppet snapshotPuppet = null;
    Composite dcomposite = null;
    int sharedCount = 0;
    static Snapshot[Puppet] handles;
    alias CaptureCallback = void delegate(Texture tex);
    CaptureCallback[] pendingCallbacks;
    static struct PendingRequest {
        Snapshot snap;
        CaptureCallback cb;
    }
    static PendingRequest[] pendingQueue;

    this(Puppet puppet) {
        sharedCount = 1;
        setup(puppet);
    }

    void setup(Puppet puppet) {
        if (dcomposite !is null) {
            if (dcomposite.textures[0] !is null) {
                dcomposite.textures[0].dispose();
                dcomposite.textures[0] = null;
            }
        }
        dcomposite = new Composite();
        snapshotPuppet = puppet;
        dcomposite.name = "Snapshot";
        dcomposite.parent(puppet.getPuppetRootNode());
        puppet.root.parent(cast(Node)dcomposite);
        dcomposite.setPuppet(puppet);
        puppet.rescanNodes();
        puppet.requestFullRenderRebuild();
        dcomposite.build();
    }

public:
    static Snapshot get(Puppet puppet) {
        if (puppet in handles) {
            handles[puppet].sharedCount ++;
            return handles[puppet];
        }
        auto result = new Snapshot(puppet);
        handles[puppet] = result;
        return result;
    }

    void release() {
        if (--sharedCount <= 0) {
            if (snapshotPuppet !is null) {
                if (snapshotPuppet.actualRoot != snapshotPuppet.root) {
                    foreach (child; dcomposite.children)
                        dcomposite.releaseChild(child);
                    snapshotPuppet.root.parent(snapshotPuppet.getPuppetRootNode());
                }
                handles.remove(snapshotPuppet);
                snapshotPuppet = null;
                dcomposite = null;
            }
        }
    }

    /// Register a callback to run after the next deferred capture is processed.
    void onCaptured(CaptureCallback cb) {
        pendingCallbacks ~= cb;
    }

    /// Schedule a capture (deferred). Does not return a texture.
    void capture() {
        // Aggregate callbacks for this instance.
        CaptureCallback aggregate;
        if (pendingCallbacks.length > 0) {
            aggregate = (tex) {
                foreach (cb; pendingCallbacks) {
                    if (cb !is null) cb(tex);
                }
                pendingCallbacks.length = 0;
            };
        }
        Snapshot.requestCapture(snapshotPuppet, (tex) {
            if (aggregate !is null) aggregate(tex);
        });
    }

    /// Queue capture to run after the next render loop finishes.
    static void requestCapture(Puppet puppet, CaptureCallback cb) {
        auto snap = get(puppet);
        pendingQueue ~= PendingRequest(snap, cb);
    }

    /// Called after the main render loop to process queued captures.
    static void processPending() {
        if (pendingQueue.length == 0) return;
        auto queue = pendingQueue.dup;
        pendingQueue.length = 0;
        foreach (req; queue) {
            // Capture snapshot offscreen now that main rendering is done.
            auto tex = req.snap.dcomposite.textures[0];
            if (req.cb !is null) req.cb(tex);
        }
    }

    vec2 position() {
        if (dcomposite) {
            vec2 pos = dcomposite.transform.translation.xy + dcomposite.textureOffset;
            return pos;
        }
        return vec2(0, 0);
    }
}
