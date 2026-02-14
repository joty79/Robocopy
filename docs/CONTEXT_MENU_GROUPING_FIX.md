# Context Menu Grouping Fix (Robo-Cut / Robo-Copy / Robo-Paste)

## Problem
- Τα `Robo-Cut` / `Robo-Copy` εμφανίζονταν σε άλλο block από το `Robo-Paste`.
- Αιτία: τα entries ήταν σε διαφορετικά registry branches (`AllFilesystemObjects` vs `Directory`), άρα ο Explorer τα renderάρει ξεχωριστά.

## Root Cause
- Το ordering (`Y_10`, `Y_11`, `Y_12`) δουλεύει αξιόπιστα μόνο όταν τα verbs είναι peers στο ίδιο branch.
- Δεν γίνεται να "κολλήσει" σταθερά το `Paste` με `Cut/Copy` όταν αυτά είναι σε διαφορετικό parent bucket.

## Final Rule
- Για `files` (`*`): βάλε `Robo-Cut` + `Robo-Copy` σε `HKCU\Software\Classes\*\shell`.
- Για `folders` (`Directory`): βάλε `Robo-Cut` + `Robo-Copy` + `Robo-Paste` όλα μαζί σε `HKCU\Software\Classes\Directory\shell`.
- Για `folder background`: βάλε μόνο `Robo-Paste` σε `HKCU\Software\Classes\Directory\Background\shell`.
- Πριν από νέο deploy, κάνε explicit cleanup των παλιών Robo keys.

## Separator Rules
- File context (`*`):
  - `SeparatorBefore` στο `Y_10_RoboCut`
  - `SeparatorAfter` στο `Y_11_RoboCopy`
- Folder context (`Directory`):
  - `SeparatorBefore` στο `Y_10_RoboCut`
  - `SeparatorAfter` στο `Y_12_RoboPaste`

## Practical Notes
- Χρησιμοποίησε πάντα `HKEY_CURRENT_USER\Software\Classes\...` για user-scope install.
- Κράτα `Y_` prefix για να μένει το Robo group πάνω από `Z_MoveTo`.
- Το reference deploy file είναι το:
  - `D:\Users\joty79\scripts\Robocopy\RoboCopy_StandAlone.reg`
