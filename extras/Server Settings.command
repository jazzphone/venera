#!/bin/bash
# Double-click in Finder: Terminal runs venera-tune.sh server (it asks for your password: it changes system settings).
# Undo: sudo "/Volumes/Venera Tools/Extras/venera-tune.sh" undo
cd "$(dirname "$0")" && sudo /bin/bash ./venera-tune.sh server
echo; read -r -p "Press Return to close this window. " _
