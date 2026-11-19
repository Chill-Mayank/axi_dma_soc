# Loads Cadence Tools for this project.
# csh, then from the sim folder: source setup.csh

# 1) The Lab's Standard Cadence setup
source /home/install/Cadence_cshrc.txt

# 2) The system sometimes forgets Xcelium, so add its folder to the search list
set path = ( /home/install/XCELIUM2009/tools/bin $path )
rehash

# 3) Tell the user what is ready
echo "Tools ready. xrun is at: `which xrun`"