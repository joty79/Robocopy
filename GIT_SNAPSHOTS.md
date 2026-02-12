# RoboCopy Git Snapshots

Τελευταίο update: 2026-02-12

## Current Local State
- Repo: `D:\Users\joty79\scripts\Robocopy`
- Branch: `multi`
- Status: `ahead 4` από `origin/multi`

## Important Commits / Tags
1. `a832ba6`  
   Tag: `multi-burst-suppress-2026-02-12`  
   Περιγραφή: burst suppression marker (`state\stage.burst`) για mixed multi-select ώστε να κόβονται duplicate staging invokes.

2. `1a40230`  
   Tag: `multi-mixed-lock-2026-02-12`  
   Περιγραφή: staging VBS lock για να αποφεύγονται `pwsh` clone bursts σε mixed multi-select copy/cut.

3. `66d6d20`  
   Tag: `multi-fast-1p8s-2026-02-12`  
   Περιγραφή: wildcard fast-path για full-folder file selections + latest performance pass.

4. `334a862`  
   Περιγραφή: context-menu fast path + reduced multi-select overhead.

5. `43088c6`  
   Tag: `multi-stable-2026-02-12`  
   Περιγραφή: stable baseline snapshot για multi-select staging/transfer.

6. `03258e7`  
   Περιγραφή: initial commit.

## Quick Commands
```powershell
cd D:\Users\joty79\scripts\Robocopy

# Δες γρήγορα commits/tags
git log --oneline --decorate -n 10
git tag --list "multi*" --sort=-creatordate

# Πήγαινε σε mixed-selection lock snapshot
git checkout multi-mixed-lock-2026-02-12

# Πήγαινε σε fast snapshot
git checkout multi-fast-1p8s-2026-02-12

# Πήγαινε σε stable baseline
git checkout multi-stable-2026-02-12

# Επιστροφή σε active branch
git switch multi
```

## Remote Sync (Optional)
Αν θέλεις να υπάρχουν αυτά και στο GitHub:
```powershell
cd D:\Users\joty79\scripts\Robocopy
git push origin multi
git push origin refs/tags/multi-burst-suppress-2026-02-12
git push origin refs/tags/multi-fast-1p8s-2026-02-12
git push origin refs/tags/multi-stable-2026-02-12
```
