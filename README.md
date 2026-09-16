DockSettings
============

DockSettings is a shell script intended to be used by handheld users with an external GPU.

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
Huge thanks to msterbi for the original idea and work!

AI DISCLOSURE: AI was used for parts of the script to save time
