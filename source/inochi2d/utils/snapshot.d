module inochi2d.utils.snapshot;

import inochi2d.core.nodes;
import inochi2d.core.nodes.composite.dcomposite;
import inochi2d.core.puppet;
import inochi2d.core.texture;

private {
    Puppet snapshotPuppet = null;
    DynamicComposite dcomposite = null;
}

Texture inSnapshot(bool forceUpdate = false)(Puppet puppet) {
    if (forceUpdate || dcomposite is null || snapshotPuppet != puppet) {
        if (dcomposite !is null) {
            if (dcomposite.textures[0] !is null) {
                dcomposite.textures[0].dispose();
                dcomposite.textures[0] = null;
            }
        }
        dcomposite = new DynamicComposite();
        snapshotPuppet = puppet;
        dcomposite.name = "Snapshot";
        dcomposite.parent(puppet.getPuppetRootNode());
        puppet.root.parent(cast(Node)dcomposite);
        dcomposite.setPuppet(puppet);
    }
    puppet.rescanNodes();
    dcomposite.setupSelf();
    dcomposite.autoResizedMesh = false;
    dcomposite.draw();
    auto tex = dcomposite.textures[0];
    return tex;
}

void inStopSnapshot(Puppet puppet) {
    if (puppet.actualRoot != puppet.root) {
        puppet.root.parent(puppet.getPuppetRootNode());
    }
}