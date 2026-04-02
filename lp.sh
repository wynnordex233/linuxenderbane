#!/bin/bash



set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

check_root() {
    [[ $EUID -eq 0 ]] || { echo -e "${RED}❌ Chạy với sudo nhé!${NC}"; exit 1; }
}

# Kiểm tra công cụ cần thiết
check_deps() {
    for cmd in parted lsblk e2fsck resize2fs; do
        command -v $cmd &>/dev/null || { 
            echo -e "${RED}❌ Thiếu $cmd. Cài đặt: sudo apt install parted e2fsprogs${NC}"
            exit 1
        }
    done
}

refresh() {
    sync
    partprobe 2>/dev/null || true
    sleep 1
}

# Lấy tên ổ đĩa từ partition (hỗ trợ NVMe + SATA)
get_disk_from_part() {
    local part="$1"
    if [[ "$part" == nvme* ]] || [[ "$part" == mmcblk* ]]; then
        # NVMe: nvme0n1p6 → nvme0n1
        # SD card: mmcblk0p1 → mmcblk0
        echo "${part%p[0-9]*}"
    else
        # SATA/IDE: sda1 → sda, vda2 → vda
        echo "${part%%[0-9]*}"
    fi
}

# Lấy số partition
get_part_number() {
    local part="$1"
    if [[ "$part" == nvme* ]] || [[ "$part" == mmcblk* ]]; then
        # nvme0n1p6 → 6
        echo "${part##*p}"
    else
        # sda1 → 1
        echo "${part##*[a-z]}"
    fi
}

show_disks() {
    echo -e "${CYAN}╔════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║         DANH SÁCH Ổ ĐĨA                ║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════╝${NC}"
    echo
    lsblk -d -o NAME,SIZE,TYPE,MODEL 2>/dev/null | grep -E "disk|nvme"
    echo
    echo -e "${YELLOW}=== Chi tiết partition ===${NC}"
    lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT,LABEL 2>/dev/null
    echo
}

# Gộp 2 partition liền kề
merge_partitions() {
    show_disks
    
    echo -e "${YELLOW}╔════════════════════════════════════════╗${NC}"
    echo -e "${YELLOW}║      GỘP 2 PARTITION LIỀN KỀ           ║${NC}"
    echo -e "${YELLOW}╚════════════════════════════════════════╝${NC}"
    echo
    echo -e "${RED}⚠️  CẢNH BÁO: Dữ liệu partition thứ 2 sẽ bị XÓA!${NC}"
    echo -e "${RED}⚠️  Hãy backup trước khi tiếp tục!${NC}"
    echo
    
    read -p "Nhập partition thứ nhất (giữ lại, vd: nvme0n1p6): " p1
    read -p "Nhập partition thứ hai (sẽ xóa, vd: nvme0n1p9): " p2
    
    # Xác định ổ đĩa và số partition
    local disk1=$(get_disk_from_part "$p1")
    local disk2=$(get_disk_from_part "$p2")
    local num1=$(get_part_number "$p1")
    local num2=$(get_part_number "$p2")
    
    echo -e "${CYAN}Debug: disk1=$disk1, disk2=$disk2, num1=$num1, num2=$num2${NC}"
    
    # Kiểm tra cùng ổ đĩa
    if [[ "$disk1" != "$disk2" ]]; then
        echo -e "${RED}❌ Hai partition không cùng ổ đĩa!${NC}"
        return 1
    fi
    
    local disk="/dev/$disk1"
    local part1="/dev/$p1"
    local part2="/dev/$p2"
    
    # Kiểm tra ổ đĩa tồn tại
    if [[ ! -b "$disk" ]]; then
        echo -e "${RED}❌ Ổ đĩa $disk không tồn tại!${NC}"
        return 1
    fi
    
    # Kiểm tra partition tồn tại
    if [[ ! -b "$part1" ]]; then
        echo -e "${RED}❌ Partition $part1 không tồn tại!${NC}"
        return 1
    fi
    
    if [[ ! -b "$part2" ]]; then
        echo -e "${RED}❌ Partition $part2 không tồn tại!${NC}"
        return 1
    fi
    
    # Lấy thông tin sector
    echo -e "${CYAN}Đang kiểm tra vị trí partition...${NC}"
    
    local end1=$(parted "$disk" unit s print 2>/dev/null | grep "^ *$num1 " | awk '{print $3}' | tr -d 's')
    local start2=$(parted "$disk" unit s print 2>/dev/null | grep "^ *$num2 " | awk '{print $2}' | tr -d 's')
    local end2=$(parted "$disk" unit s print 2>/dev/null | grep "^ *$num2 " | awk '{print $3}' | tr -d 's')
    
    echo "Partition $num1 kết thúc tại sector: $end1"
    echo "Partition $num2 bắt đầu tại sector: $start2"
    echo "Partition $num2 kết thúc tại sector: $end2"
    
    if [[ -z "$end1" ]] || [[ -z "$start2" ]] || [[ -z "$end2" ]]; then
        echo -e "${RED}❌ Không đọc được thông tin partition!${NC}"
        return 1
    fi
    
    # Kiểm tra liền kề (cho phép gap nhỏ < 2048 sectors = 1MB)
    local gap=$((start2 - end1))
    if [[ $gap -gt 2048 ]]; then
        echo -e "${RED}❌ Hai partition không liền kề (khoảng cách: $gap sectors)!${NC}"
        return 1
    fi
    
    # Xác nhận lần cuối
    echo
    echo -e "${YELLOW}Sẽ thực hiện:${NC}"
    echo "  1. Xóa partition $p2"
    echo "  2. Mở rộng partition $p1 đến sector $end2"
    echo
    read -p "Xác nhận? (yes/no): " confirm
    [[ "$confirm" == "yes" ]] || { echo "Đã hủy."; return; }
    
    # Unmount cả 2
    echo -e "${CYAN}Unmount partition...${NC}"
    umount "$part1" 2>/dev/null || true
    umount "$part2" 2>/dev/null || true
    sleep 1
    
    # Xóa partition 2
    echo -e "${CYAN}Xóa partition $num2...${NC}"
    parted "$disk" rm "$num2"
    refresh
    
    # Resize partition 1
    echo -e "${CYAN}Mở rộng partition $num1...${NC}"
    parted "$disk" resizepart "$num1" "${end2}s"
    refresh
    
    # Kiểm tra filesystem
    local fstype=$(lsblk -no FSTYPE "$part1" 2>/dev/null)
    echo "Filesystem: $fstype"
    
    if [[ "$fstype" == "ext4" ]] || [[ "$fstype" == "ext3" ]]; then
        echo -e "${CYAN}Kiểm tra và resize ext4...${NC}"
        e2fsck -f "$part1" || true
        resize2fs "$part1"
    elif [[ "$fstype" == "xfs" ]]; then
        echo -e "${CYAN}XFS cần mount trước khi resize${NC}"
        mkdir -p /tmp/xfs_resize
        mount "$part1" /tmp/xfs_resize
        xfs_growfs /tmp/xfs_resize
        umount /tmp/xfs_resize
    elif [[ "$fstype" == "ntfs" ]]; then
        echo -e "${YELLOW}⚠️  NTFS: Dùng ntfsresize để mở rộng${NC}"
        ntfsresize -f "$part1" || echo "Cài ntfs-3g nếu cần"
    fi
    
    refresh
    echo -e "${GREEN}✅ Gộp thành công! Partition mới: $p1${NC}"
    lsblk "$part1" -o NAME,SIZE,FSTYPE
}

# Tạo partition mới
create_partition() {
    show_disks
    
    echo -e "${YELLOW}Nhập tên ổ đĩa (vd: sda, nvme0n1):${NC}"
    read diskname
    local disk="/dev/$diskname"
    
    [[ -b "$disk" ]] || { echo -e "${RED}Ổ không tồn tại!${NC}"; return; }
    
    echo -e "${CYAN}Không gian trống:${NC}"
    parted "$disk" unit GB print free 2>/dev/null | grep -i free || echo "Không có không gian trống"
    
    echo
    echo "Nhập kích thước (vd: 50GB, 100GB, hoặc 100% cho hết):"
    read size
    
    echo "Nhập loại filesystem (ext4/ntfs/xfs/fat32):"
    read fs
    
    # Tìm vị trí trống cuối
    local lastend=$(parted "$disk" unit MB print 2>/dev/null | tail -2 | head -1 | awk '{print $3}')
    
    echo -e "${CYAN}Tạo partition mới...${NC}"
    parted -s "$disk" mkpart primary "$fs" "$lastend" "$size"
    refresh
    
    # Format partition mới
    local newpart=$(lsblk -rno NAME "$disk" | tail -1)
    echo -e "${CYAN}Format /dev/$newpart với $fs...${NC}"
    
    case $fs in
        ext4) mkfs.ext4 -F "/dev/$newpart" ;;
        ntfs) mkfs.ntfs -f "/dev/$newpart" ;;
        xfs) mkfs.xfs -f "/dev/$newpart" ;;
        fat32) mkfs.vfat -F32 "/dev/$newpart" ;;
    esac
    
    echo -e "${GREEN}✅ Tạo thành công /dev/$newpart${NC}"
}

# Xóa partition
delete_partition() {
    show_disks
    
    echo "Nhập partition cần xóa (vd: sda3, nvme0n1p5):"
    read partname
    
    local part="/dev/$partname"
    local disk="/dev/$(get_disk_from_part "$partname")"
    local num=$(get_part_number "$partname")
    
    [[ -b "$part" ]] || { echo -e "${RED}Partition không tồn tại!${NC}"; return; }
    
    echo -e "${RED}⚠️  Xóa $part? Dữ liệu sẽ MẤT!${NC}"
    read -p "Xác nhận (yes/no): " confirm
    [[ "$confirm" == "yes" ]] || return
    
    umount "$part" 2>/dev/null || true
    parted "$disk" rm "$num"
    refresh
    
    echo -e "${GREEN}✅ Đã xóa $part${NC}"
}

# Resize partition
resize_partition() {
    show_disks
    
    echo "Nhập partition cần resize (vd: sda2, nvme0n1p3):"
    read partname
    
    local part="/dev/$partname"
    local disk="/dev/$(get_disk_from_part "$partname")"
    local num=$(get_part_number "$partname")
    
    [[ -b "$part" ]] || { echo -e "${RED}Partition không tồn tại!${NC}"; return; }
    
    echo "Nhập kích thước mới (vd: 100GB, hoặc 100% cho hết ổ):"
    read newsize
    
    umount "$part" 2>/dev/null || true
    
    local fstype=$(lsblk -no FSTYPE "$part")
    
    if [[ "$fstype" == "ext4" ]]; then
        e2fsck -f "$part"
    fi
    
    parted "$disk" resizepart "$num" "$newsize"
    refresh
    
    if [[ "$fstype" == "ext4" ]]; then
        resize2fs "$part"
    fi
    
    echo -e "${GREEN}✅ Resize thành công $part${NC}"
}

# Menu chính
main_menu() {
    while true; do
        clear
        echo -e "${GREEN}╔══════════════════════════════════════════╗${NC}"
        echo -e "${GREEN}║   LPARTITION v2.0 - Công cụ Việt Nam     ║${NC}"
        echo -e "${GREEN}║   Hỗ trợ: NVMe, SATA, SD Card            ║${NC}"
        echo -e "${GREEN}╚══════════════════════════════════════════╝${NC}"
        echo
        echo "  1) 📋 Xem ổ đĩa & partition"
        echo "  2) ➕ Tạo partition mới"
        echo "  3) 🔄 Resize partition"
        echo "  4) 🔗 Gộp 2 partition liền kề"
        echo "  5) ❌ Xóa partition"
        echo "  6) 🚪 Thoát"
        echo
        read -p "Chọn [1-6]: " opt
        
        case $opt in
            1) show_disks; read -p "Enter để tiếp..." ;;
            2) create_partition; read -p "Enter để tiếp..." ;;
            3) resize_partition; read -p "Enter để tiếp..." ;;
            4) merge_partitions; read -p "Enter để tiếp..." ;;
            5) delete_partition; read -p "Enter để tiếp..." ;;
            6) echo "Bye!"; exit 0 ;;
            *) echo "Chọn lại!" ;;
        esac
    done
}

# Main
check_root
check_deps
main_menu
