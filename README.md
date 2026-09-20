DockSettings
============

DockSettings is a shell script intended to be used by handheld users with an external GPU.
*I highly recommend disabling Vulkan shader pre-caching on Steam, as the script does not handle these yet.* You can disable them under the Steam Download Settings (in Desktop Mode). Shaders will have to compile once per GPU in-game since there will be no cache downloaded for Steam's servers, but at least, the cache won't redownload and recompile every time you switch GPUs. A proper Steam shader cache handler is something I'm planning to implement in the future.

```
Usage: ./docksettings.sh [options]

Options:
  -g [state]  Target GPU state (igpu/egpu)
  -d          Dry run: Log changes without writing
  -h          Show help message

Examples:
  ./docksettings.sh -g egpu    # Update map and switch to eGPU
  ./docksettings.sh -g igpu    # Update map and switch to iGPU
  ./docksettings.sh -g egpu -d # Dry run (test without changes)
```

Clone this repo wherever you'd like your settings to be backed up.

Put 99-...rules file in the /etc/udev/rules.d/ folder.


The script will auto backup configuration files and shader cache from Proton Prefixes (seperate backups for iGPU/eGPU usage) and apply them depending on which GPU is being used.
You can also add additional files/folders to track in the .csv file.

You'd ideally want this script to be called whenever you switch GPUs. The udev rule can work for this, but I personally use Steam shortcuts with launch parameters for more direct control.

### Credits
Huge thanks to msterbi for the original concept.

AI DISCLOSURE: AI was used for debugging to save time.
