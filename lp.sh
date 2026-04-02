#!/bin/bash
# lpartition.sh - Công cụ chia & gộp ổ cứng Linux (by Grok + bạn)
# Chạy với sudo: sudo ./lpartition.sh

set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

check_root() {
    [[ $EUID -eq 0 ]] || { echo -e "${RED}Chạy với sudo nhé!${NC}"; exit 1; }
}

refresh() {
    sync; partprobe >/dev/null 2>&1 || true
    sleep 1
}

show_disks() {
    echo -e "${YELLOW}=== Danh sách ổ đĩa ===${NC}"
    lsblk -d -o NAME,SIZE,TYPE,MODEL | grep disk
    echo
    echo -e "${YELLOW}=== Partition hiện tại ===${NC}"
    lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT,LABEL
}

select_disk() {
    echo -e "${YELLOW}Nhập tên ổ đĩa (vd: sda, sdb, nvme0n1):${NC} "
    read disk
    disk="/dev/$disk"
    [[ -b "$disk" ]] || { echo "Ổ không tồn tại!"; exit 1; }
}

# Gộp 2 partition liền kề
merge_partitions() {
    show_disks
    echo -e "${YELLOW}Gộp 2 partition liền kề${NC}"
    echo "Nhập partition đầu tiên (vd: sda2): "
    read p1
    echo "Nhập partition thứ hai (liền kề ngay sau, vd: sda3): "
    read p2

    part1="/dev/$p1"; part2="/dev/$p2"

    # Kiểm tra liền kề
    start1=$(parted "$disk" unit s print | grep "^ ${p1:5}" | awk '{print $2}' | tr -d s)
    start2=$(parted "$disk" unit s print | grep "^ ${p2:5}" | awk '{print $2}' | tr -d s)
    end1=$(parted "$disk" unit s print | grep "^ ${p1:5}" | awk '{print $3}' | tr -d s)

    [[ $((start2 - end1)) -eq 1 ]] || { echo -e "${RED}Hai partition không liền kề!${NC}"; return; }

    # Unmount trước
    umount "$part1" 2>/dev/null || true
    umount "$part2" 2>/dev/null || true

    echo -e "${YELLOW}Đang gộp $p1 + $p2 ...${NC}"
    parted "$disk" rm "${p2:5}"
    parted "$disk" resizepart "${p1:5}" 100%
    e2fsck -f "$part1"
    resize2fs "$part1"
    refresh
    echo -e "${GREEN}Gộp thành công! Partition mới: $p1${NC}"
}

# Chia mới / resize
create_or_resize() {
    show_disks
    select_disk

    echo "1) Tạo partition mới"
    echo "2) Resize (phóng to) partition hiện có"
    read -p "Chọn: " choice

    if [[ $choice -eq 1 ]]; then
        parted -s "$disk" print free | grep "free space" | tail -1
        echo "Nhập kích thước mới (vd: 50GB, 500GB, -1 cho hết): "
        read size
        echo "Nhập loại filesystem (ext4/ntfs/xfs): "
        read fs

        echo "Tạo partition cuối ổ..."
        parted -s "$disk" mkpart primary "$fs" 0% "$size"
        refresh
        newpart=$(lsblk -rno NAME "$disk" | tail -1)
        mkfs."$fs" -F "/dev/$newpart" -L "Data"
        echo -e "${GREEN}Tạo thành công /dev/$newpart${NC}"
    else
        echo "Nhập partition cần phóng to (vd: sda2): "
        read part
        umount "/dev/$part" 2>/dev/null || true
        e2fsck -f "/dev/$part"
        parted "$disk" resizepart "${part:5}" 100%
        resize2fs "/dev/$part"
        echo -e "${GREEN}Resize thành công /dev/$part${NC}"
    fi
}

main_menu() {
    while true; do
        clear
        echo -e "${GREEN}╔══════════════════════════════════╗${NC}"
        echo -e "${GREEN}║       LPARTITION - Công cụ Việt  ║${NC}"
        echo -e "${GREEN}╚══════════════════════════════════╝${NC}"
        echo "1) Xem ổ đĩa & partition"
        echo "2) Chia ổ / Tạo partition mới / Resize"
        echo "3) Gộp 2 partition liền kề (an toàn)"
        echo "4) Xóa partition"
        echo "5) Thoát"
        echo
        read -p "Chọn chức năng [1-5]: " opt
        case $opt in
            1) show_disks; read -p "Enter để tiếp..." ;;
            2) create_or_resize; read -p "Enter để tiếp..." ;;
            3) merge_partitions; read -p "Enter để tiếp..." ;;
            4) 
                show_disks
                echo "Nhập partition cần xóa (vd: sda3): "
                read del
                umount "/dev/$del" 2>/dev/null || true
                parted "/dev/${del%%[0-9]*}" rm "${del: -1}" 2>/dev/null || parted "/dev/${del%%[0-9]*}" rm "${del##*[a-z]}" 
                echo -e "${GREEN}Đã xóa /dev/$del${NC}"
                read -p "Enter để tiếp..."
                ;;
            5) echo "Bye!"; exit 0 ;;
            *) echo "Sai rồi chọn lại!" ;;
        esac
    done
}

check_root
main_menu
