module inochi2d.utils.snapshot;

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
            dcomposite.textures[0].dispose();
            dcomposite.textures[0] = null;
            if (dcomposite == puppet.root) {
                puppet.root = dcomposite.children[0];
            }
        }
        dcomposite = new DynamicComposite();
        snapshotPuppet = puppet;
        dcomposite.name = "Snapshot";
        puppet.getPuppetRootNode().parent(dcomposite);
        puppet.root = dcomposite;
        dcomposite.setPuppet(puppet);
    }
//    dcomposite.scanSubParts([puppet.getPuppetRootNode()]);
    dcomposite.scanParts();
    dcomposite.setupSelf();
    dcomposite.autoResizedMesh = false;
    dcomposite.draw();
    /*
    dcomposite.setPuppet(snapshotPuppet);
    foreach (child; puppet.getRootParts()) {
        dcomposite.setupChild(child);
    }
    dcomposite.scanSubParts(puppet.getRootParts());
    dcomposite.setupSelf();
    dcomposite.autoResizedMesh = false;
    dcomposite.invalidate();
    dcomposite.drawContents();
    */
    auto tex = dcomposite.textures[0];
    return tex;
}