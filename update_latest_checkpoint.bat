@echo off
title Sync Latest OpenKhmer Private Checkpoint + Start Studio
cd /d "%~dp0"
set HF_HUB_DISABLE_XET=1
set AUTO_PULL_LATEST_CHECKPOINT=1

call run.bat
