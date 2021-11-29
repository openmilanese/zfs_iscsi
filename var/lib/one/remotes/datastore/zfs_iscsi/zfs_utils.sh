# ----------------------------------------------------------------------------- #
# Copyright 2002-2019, OpenNebula Project (OpenNebula.org), C12G Labs           #
#                                                                               #
# Licensed under the Apache License, Version 2.0 (the "License"); you may       #
# not use this file except in compliance with the License. You may obtain       #
# a copy of the License at                                                      #
#                                                                               #
# http://www.apache.org/licenses/LICENSE-2.0                                    #
#                                                                               #
# Unless required by applicable law or agreed to in writing, software           #
# distributed under the License is distributed on an "AS IS" BASIS,             #
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.      #
# See the License for the specific language governing permissions and           #
# limitations under the License.                                                #
#------------------------------------------------------------------------------ #

#--------------------------------------------------------------------------------
# Make a base @snap for image clones
#  @param $1 the volume
#--------------------------------------------------------------------------------
zvol_make_snap() {
    $SUDO zfs list -H -r -t snapshot -o name "$1@snap" >/dev/null 2>&1

    if [ "$?" != "0" ]; then
	$SUDO zfs snapshot "$1@snap"
	$SUDO zfs hold keep "$1@snap"
    fi
}

#--------------------------------------------------------------------------------
# Remove the base @snap for image clones
#  @param $1 the volume
#  @param $2 (Optional) the snapshot name. If empty it defaults to 'snap'
#--------------------------------------------------------------------------------
zvol_rm_snap() {
    local snap
    snap=${2:-snap}

    $SUDO zfs list -H -r -t snapshot -o name "$1@$snap" >/dev/null 2>&1

    if [ "$?" = "0" ]; then
        $SUDO zfs release keep "$1@$snap"
        $SUDO zfs destroy "$1@$snap"
    fi
}

#--------------------------------------------------------------------------------
# Find the snapshot in current volume or any of the snapshot volumes
#   @param $1 volume base, i.e. <pool>/one-<image_id>[-<vm_id>-<disk_id>]
#   @param $2 snapshot id
#   @return volume name, exits if not found
#--------------------------------------------------------------------------------
zvol_find_snap() {
    local zvol_tgt pool vol

    $SUDO zfs list -H -r -t snapshot -o name $1 | grep -q "$1@$2"

    if [ "$?" = "0" ]; then
        zvol_tgt=$1
    else
        zvol_tgt=$($SUDO zfs list -H -r -o name | grep -E "$1-(.+:)?$2(:|$)")

        if [ -z "${zvol_tgt}" ]; then
            echo "Could not find a volume with snapshot $2" >&2
            exit 1
        fi
    fi

    echo $zvol_tgt
}

#--------------------------------------------------------------------------------
# Rename the target volume to include the snapshot list or remove it if it has
# no snapshots
#   @param $1 volume base, i.e. <pool>/one-<image_id>[-<vm_id>-<disk_id>]
#   @param $2 volume to rename or remove
#--------------------------------------------------------------------------------
zvol_rename_rm() {
    local snapids

    snapids=$($SUDO zfs list -H -r -t snapshot -o name $2 | grep -Po '(?<=@)\d+' | paste -d: -s)

    if [ -z "$snapids" ]; then
	$SUDO zfs destroy $2
    else
	$SUDO zfs rename $2 $1-$snapids
    fi
}

#--------------------------------------------------------------------------------
# Remove snapshot suffixes (if exists)
#   @param the volume
#     example: one-2-39-0-0:1:2 or one/one-2-39-0-0:1:2
#   @return volume without snapshot suffixes
#     example: one-2-39-0 or one/one-2-39-0
#--------------------------------------------------------------------------------
trim_snapshot_suffix() {
    echo $1 | sed  's/\([^-]*-[0-9]*-[0-9]*-[0-9]*\).*/\1/'
}

#--------------------------------------------------------------------------------
# Get volume parent volume (if exists)
#   @param the volume including pool in format pool/volume
#   @return parent volume in same format
#--------------------------------------------------------------------------------
zvol_get_parent() {
    parent_snap=$($SUDO zfs get -H -o value origin $1)
    echo $parent_snap | sed 's/@.*//' # remove @snap string
}

#--------------------------------------------------------------------------------
# Get top parent of a snapshot hierarchy if the volume has snapshots.
#   @param $1 the volume
#   @return the top parent or volume in no snapshots found
#--------------------------------------------------------------------------------
zvol_top_parent() {
    local volume
    volume=$1 # format: pool/volume; such as one/one-2-38-0
    volume_no_snapshots=$(trim_snapshot_suffix $1)

    while true; do
        parent=$(zvol_get_parent $volume)

        # until there is no parent or the parent is the original image
        # like `one-0` which is not matching the `one-x-y-z` volume pattern
        if echo $parent | grep -q $volume_no_snapshots > /dev/null 2>&1; then
            volume=$parent
        else
            echo $volume
            return 0
        fi
    done

    echo $1
}

#--------------------------------------------------------------------------------
# Remove all the images and snapshots from a given volume
#   @param $1 the volume (or snapshot to delete)
#--------------------------------------------------------------------------------
zvol_rm_r() {
    local zvol zvol_base children snaps

    zvol=$1
    zvol_base=${zvol%%@*}

    if [ "$zvol" != "$zvol_base" ]; then
        children=$($SUDO zfs get -H clones -o value $zvol 2>/dev/null)

        for child in $children; do
            zvol_rm_r $child
        done

        $SUDO zfs release keep $zvol
        $SUDO zfs destroy $zvol
    else
        snaps=$($SUDO zfs list -H -r -t snapshot -o name $zvol 2>/dev/null)

        for snap in $snaps; do
            zvol_rm_r $snap
        done

        $SUDO zfs destroy $zvol
    fi
}

