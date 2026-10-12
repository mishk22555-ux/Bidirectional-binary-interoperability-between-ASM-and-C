; ==============================================================================
; app_nasm.asm
; Программа на ассемблере NASM (x86-64 Linux) для бинарного обмена данными с C
;
; Описание задачи:
; 1. Программа взаимодействует с парной программой на C (app_c).
; 2. Обмен данными происходит в строго двоичном (бинарном) формате через
;    специальную поддиректорию проекта: bin_exchange/
; 3. Программа работает в двух режимах (автоматически или через аргументы):
;    - ЭТАП 1 (Генерация): Создает папку bin_exchange/ и записывает двоичную
;      структуру данных (asm_to_c.bin) с сигнатурой "NASM", версией, количеством
;      элементов, массивом чисел int64 и контрольной суммой.
;    - ЭТАП 3 (Верификация): Считывает двоичный ответ от C (c_to_asm.bin),
;      проверяет сигнатуру "C_OK", валидирует полученные числа и общую сумму,
;      после чего сохраняет финальный отчет (final_report.bin) с сигнатурой "DONE".
;
; Все системные вызовы выполняются напрямую через интерфейс ядра Linux (syscall)
; без использования стандартной библиотеки C (libc).
; ==============================================================================

global _start

; ------------------------------------------------------------------------------
; Константы системных вызовов Linux x86-64
; ------------------------------------------------------------------------------
SYS_READ        equ 0
SYS_WRITE       equ 1
SYS_OPEN        equ 2
SYS_CLOSE       equ 3
SYS_ACCESS      equ 21
SYS_EXIT        equ 60
SYS_MKDIR       equ 83

; Файловые дескрипторы стандартных потоков
STDOUT_FD       equ 1
STDERR_FD       equ 2

; Флаги открытия файлов (sys_open):
; O_RDONLY = 0
; O_WRONLY (0x1) | O_CREAT (0x40) | O_TRUNC (0x200) = 0x241 (577 в десятичной)
O_RDONLY        equ 0
O_CREAT_WRTRUNC equ 577

; Права доступа к создаваемым файлам и папкам:
; 0644 (восьмерич.) = 420 (десят.) - rw-r--r-- для файлов
; 0755 (восьмерич.) = 493 (десят.) - rwxr-xr-x для каталогов
MODE_FILE       equ 420
MODE_DIR        equ 493

; Константы протокола бинарного обмена
PACKET_SIZE     equ 64      ; Размер пакета: 4+4+4+4 + (5*8) + 8 = 64 байта
REPORT_SIZE     equ 32      ; Размер финального отчета: 4+4+8+8+8 = 32 байта
ITEMS_COUNT     equ 5       ; Количество чисел в пакете

; ------------------------------------------------------------------------------
; Секция инициализированных данных (.data)
; ------------------------------------------------------------------------------
section .data

    ; Имена каталога и бинарных файлов обмена
    dir_name        db "bin_exchange", 0
    file_asm_out    db "bin_exchange/asm_to_c.bin", 0
    file_c_in       db "bin_exchange/c_to_asm.bin", 0
    file_final_out  db "bin_exchange/final_report.bin", 0

    ; Аргументы командной строки для принудительного выбора режима
    arg_send        db "send", 0
    arg_recv        db "recv", 0

    ; --------------------------------------------------------------------------
    ; Бинарная структура для отправки в C: PacketFromAsm (64 байта)
    ; Смещение:
    ;   +00: magic (4 байта)       - "NASM" (0x4D53414E в little-endian)
    ;   +04: version (4 байта)     - uint32 = 1
    ;   +08: count (4 байта)       - uint32 = 5
    ;   +12: reserved (4 байта)    - uint32 = 0 (выравнивание)
    ;   +16: numbers (40 байт)     - 5 чисел int64: 10, 25, 42, 100, 256
    ;   +56: checksum (8 байт)     - uint64 = 433 (10+25+42+100+256)
    ; --------------------------------------------------------------------------
    align 8
    asm_packet:
        db "NASM"                  ; Сигнатура протокола
        dd 1                       ; Версия 1
        dd ITEMS_COUNT             ; Количество элементов (5)
        dd 0                       ; Резерв / выравнивание
        dq 10, 25, 42, 100, 256    ; Исходные данные (64-битные знаковые числа)
        dq 433                     ; Контрольная сумма: 10 + 25 + 42 + 100 + 256

    ; --------------------------------------------------------------------------
    ; Бинарная структура финального отчета: PacketReport (32 байта)
    ; Смещение:
    ;   +00: magic (4 байта)       - "DONE"
    ;   +04: status (4 байта)      - uint32 = 0 (УСПЕХ)
    ;   +08: verified_sum (8 байт) - uint64 (проверенная сумма от C)
    ;   +16: salt_stamp (8 байт)   - uint64 = 0x1337BEEF
    ;   +24: reserved (8 байт)     - uint64 = 0
    ; --------------------------------------------------------------------------
    align 8
    final_report:
        db "DONE"
        dd 0                       ; Статус: 0 (ОК)
        dq 0                       ; verified_sum (заполняется при проверке)
        dq 0x1337BEEF              ; Метка времени / контрольная соль
        dq 0                       ; Резерв

    ; Текстовые сообщения для консоли
    msg_banner_send db "[NASM] === ЭТАП 1: Генерация бинарных данных для C ===", 10, 0
    msg_dir_ok      db "[NASM] Каталог 'bin_exchange/' готов.", 10, 0
    msg_write_ok    db "[NASM] Успешно записан бинарный файл: bin_exchange/asm_to_c.bin (64 байта)", 10, 0
    msg_send_hint   db "[NASM] Данные отправлены! Теперь запустите программу на C: ./app_c", 10, 10, 0

    msg_banner_recv db "[NASM] === ЭТАП 3: Получение и проверка бинарных данных от C ===", 10, 0
    msg_read_ok     db "[NASM] Успешно прочитан файл: bin_exchange/c_to_asm.bin (64 байта)", 10, 0
    msg_magic_ok    db "[NASM] Сигнатура ответа 'C_OK' подтверждена!", 10, 0
    msg_val_header  db "[NASM] Прочитаны обработанные числа от C:", 10, 0
    msg_val_item_1  db "       - Элемент [", 0
    msg_val_item_2  db "]: ", 0
    msg_sum_c       db "[NASM] Сумма, заявленная C: ", 0
    msg_sum_calc    db "[NASM] Контрольная сумма, вычисленная NASM: ", 0
    msg_check_ok    db "[NASM] ПРОВЕРКА ПРОЙДЕНА: Контрольные суммы полностью совпадают!", 10, 0
    msg_report_ok   db "[NASM] Финальный бинарный отчет сохранен в bin_exchange/final_report.bin (32 байта)", 10, 0
    msg_done_all    db "[NASM] Полный цикл двустороннего бинарного обмена успешно завершен!", 10, 10, 0

    msg_already_done db "[NASM] Обмен уже был завершен ранее (найден bin_exchange/final_report.bin).", 10
                     db "       Чтобы повторить цикл с нуля, выполните: make clean", 10, 10, 0

    ; Сообщения об ошибках
    err_mkdir       db "[NASM ОШИБКА] Не удалось создать каталог bin_exchange/", 10, 0
    err_open_write  db "[NASM ОШИБКА] Не удалось открыть файл для записи!", 10, 0
    err_open_read   db "[NASM ОШИБКА] Не удалось открыть файл bin_exchange/c_to_asm.bin для чтения!", 10
                    db "             Сначала запустите программу на C: ./app_c", 10, 0
    err_magic       db "[NASM ОШИБКА] Неверная сигнатура в файле от C (ожидалось 'C_OK')!", 10, 0
    err_checksum    db "[NASM ОШИБКА] Несовпадение контрольной суммы данных от C!", 10, 0

    newline         db 10, 0

; ------------------------------------------------------------------------------
; Секция неинициализированных данных (.bss)
; ------------------------------------------------------------------------------
section .bss
    align 8
    recv_buffer     resb 128    ; Буфер для чтения структуры PacketFromC (64 байта)
    num_str_buf     resb 32     ; Буфер для форматирования чисел в ASCII строку

; ------------------------------------------------------------------------------
; Секция исполняемого кода (.text)
; ------------------------------------------------------------------------------
section .text

_start:
    ; --------------------------------------------------------------------------
    ; Анализ аргументов командной строки:
    ; На вершине стека [rsp] находится argc (int64)
    ; [rsp + 8]  - argv[0] (имя текущей программы)
    ; [rsp + 16] - argv[1] (первый аргумент, если argc >= 2)
    ; --------------------------------------------------------------------------
    mov rbx, [rsp]              ; rbx = argc
    cmp rbx, 2
    jl .auto_detect             ; Если аргументов нет, переходим к автоопределению

    ; Проверяем, передан ли аргумент "send"
    mov rdi, [rsp + 16]         ; rdi = argv[1]
    mov rsi, arg_send           ; rsi = "send"
    call strcmp
    test eax, eax
    jz mode_send                ; Если аргумент == "send", запускаем отправку

    ; Проверяем, передан ли аргумент "recv"
    mov rdi, [rsp + 16]         ; rdi = argv[1]
    mov rsi, arg_recv           ; rsi = "recv"
    call strcmp
    test eax, eax
    jz mode_recv                ; Если аргумент == "recv", запускаем прием

.auto_detect:
    ; --------------------------------------------------------------------------
    ; Автоматический выбор режима на основе существующих файлов:
    ; 1. Если final_report.bin уже существует -> цикл завершен.
    ; 2. Если существует c_to_asm.bin -> C уже ответил, запускаем этап 3 (recv).
    ; 3. Иначе -> запускаем этап 1 (send).
    ; --------------------------------------------------------------------------
    ; Проверка наличия final_report.bin через sys_access(file, F_OK=0)
    mov rax, SYS_ACCESS
    mov rdi, file_final_out
    mov rsi, 0                  ; F_OK (проверка существования)
    syscall
    test rax, rax
    jz .report_exists           ; rax == 0 означает файл существует

    ; Проверка наличия c_to_asm.bin
    mov rax, SYS_ACCESS
    mov rdi, file_c_in
    mov rsi, 0
    syscall
    test rax, rax
    jz mode_recv                ; Ответ от C есть -> режим верификации

    ; Если ответа от C нет -> начинаем с этапа 1
    jmp mode_send

.report_exists:
    mov rsi, msg_already_done
    call print_string
    xor rdi, rdi                ; Код возврата 0
    jmp exit_program

; ==============================================================================
; РЕЖИМ 1: Отправка данных (Этап 1)
; ==============================================================================
mode_send:
    mov rsi, msg_banner_send
    call print_string

    ; 1. Создаем каталог bin_exchange/ через sys_mkdir(dir_name, 0755)
    mov rax, SYS_MKDIR
    mov rdi, dir_name
    mov rsi, MODE_DIR
    syscall
    ; Код возврата < 0 может быть ошибкой, но если это -17 (-EEXIST),
    ; значит папка уже создана ранее — это нормальная ситуация.
    cmp rax, 0
    jge .dir_created
    cmp rax, -17                ; -EEXIST: папка уже существует
    je .dir_created

    ; Если другая ошибка создания каталога
    mov rsi, err_mkdir
    call print_string
    mov rdi, 1
    jmp exit_program

.dir_created:
    mov rsi, msg_dir_ok
    call print_string

    ; 2. Открываем файл bin_exchange/asm_to_c.bin для записи
    ; sys_open(file_asm_out, O_WRONLY|O_CREAT|O_TRUNC, 0644)
    mov rax, SYS_OPEN
    mov rdi, file_asm_out
    mov rsi, O_CREAT_WRTRUNC
    mov rdx, MODE_FILE
    syscall
    cmp rax, 0
    jl .err_open
    mov r12, rax                ; r12 = файловый дескриптор открытого файла

    ; 3. Записываем 64 байта бинарной структуры asm_packet
    ; sys_write(fd, buffer, count)
    mov rax, SYS_WRITE
    mov rdi, r12
    mov rsi, asm_packet
    mov rdx, PACKET_SIZE
    syscall
    cmp rax, PACKET_SIZE
    jne .err_write

    ; 4. Закрываем файл: sys_close(fd)
    mov rax, SYS_CLOSE
    mov rdi, r12
    syscall

    mov rsi, msg_write_ok
    call print_string
    mov rsi, msg_send_hint
    call print_string

    xor rdi, rdi                ; Код выхода: 0
    jmp exit_program

.err_open:
    mov rsi, err_open_write
    call print_string
    mov rdi, 1
    jmp exit_program

.err_write:
    mov rax, SYS_CLOSE
    mov rdi, r12
    syscall
    mov rsi, err_open_write
    call print_string
    mov rdi, 1
    jmp exit_program

; ==============================================================================
; РЕЖИМ 2: Прием данных от C и верификация (Этап 3)
; ==============================================================================
mode_recv:
    mov rsi, msg_banner_recv
    call print_string

    ; 1. Открываем файл bin_exchange/c_to_asm.bin для чтения
    ; sys_open(file_c_in, O_RDONLY, 0)
    mov rax, SYS_OPEN
    mov rdi, file_c_in
    mov rsi, O_RDONLY
    xor rdx, rdx
    syscall
    cmp rax, 0
    jl .err_open_read
    mov r12, rax                ; r12 = fd файла

    ; 2. Читаем бинарный пакет (64 байта) в буфер recv_buffer
    ; sys_read(fd, recv_buffer, 64)
    mov rax, SYS_READ
    mov rdi, r12
    mov rsi, recv_buffer
    mov rdx, PACKET_SIZE
    syscall
    cmp rax, PACKET_SIZE
    jne .err_read_size

    ; 3. Закрываем прочитанный файл
    mov rax, SYS_CLOSE
    mov rdi, r12
    syscall

    mov rsi, msg_read_ok
    call print_string

    ; 4. Проверяем сигнатуру заголовка (magic: "C_OK" = 0x4B4F5F43)
    ; Смещение +0: 4 байта
    mov eax, dword [recv_buffer]
    cmp eax, 0x4B4F5F43         ; "C_OK" в little-endian: 'C'(0x43), '_'(0x5F), 'O'(0x4F), 'K'(0x4B)
    jne .err_invalid_magic

    mov rsi, msg_magic_ok
    call print_string

    ; 5. Выводим полученные значения и подсчитываем контрольную сумму
    ; recv_buffer + 16 содержит массив из 5 чисел int64: results[5]
    ; recv_buffer + 56 содержит total_sum (uint64)
    mov rsi, msg_val_header
    call print_string

    xor r13, r13                ; r13 = индекс цикла (0 .. ITEMS_COUNT - 1)
    xor r14, r14                ; r14 = накапливаемая сумма для валидации

.loop_elements:
    cmp r13, ITEMS_COUNT
    jge .loop_done

    ; Печать префикса элемента: "       - Элемент ["
    mov rsi, msg_val_item_1
    call print_string
    mov rax, r13
    call print_uint64
    mov rsi, msg_val_item_2
    call print_string

    ; Загрузка числа: recv_buffer + 16 + (r13 * 8)
    mov rax, [recv_buffer + 16 + r13 * 8]
    add r14, rax                ; Добавляем к контрольной сумме
    call print_int64
    mov rsi, newline
    call print_string

    inc r13
    jmp .loop_elements

.loop_done:
    ; 6. Выводим заявленную C сумму
    mov rsi, msg_sum_c
    call print_string
    mov r15, [recv_buffer + 56] ; r15 = total_sum из бинарного пакета
    mov rax, r15
    call print_uint64
    mov rsi, newline
    call print_string

    ; Выводим сумму, вычисленную ассемблером
    mov rsi, msg_sum_calc
    call print_string
    mov rax, r14
    call print_uint64
    mov rsi, newline
    call print_string

    ; Сравниваем контрольные суммы
    cmp r14, r15
    jne .err_checksum_fail

    mov rsi, msg_check_ok
    call print_string

    ; 7. Формируем финальный бинарный отчет: PacketReport (32 байта)
    ; final_report + 8 = verified_sum (r14)
    mov [final_report + 8], r14

    ; Записываем финальный отчет в bin_exchange/final_report.bin
    mov rax, SYS_OPEN
    mov rdi, file_final_out
    mov rsi, O_CREAT_WRTRUNC
    mov rdx, MODE_FILE
    syscall
    cmp rax, 0
    jl .err_open_report
    mov r12, rax

    mov rax, SYS_WRITE
    mov rdi, r12
    mov rsi, final_report
    mov rdx, REPORT_SIZE
    syscall

    mov rax, SYS_CLOSE
    mov rdi, r12
    syscall

    mov rsi, msg_report_ok
    call print_string
    mov rsi, msg_done_all
    call print_string

    xor rdi, rdi                ; Успешный выход с кодом 0
    jmp exit_program

.err_open_read:
    mov rsi, err_open_read
    call print_string
    mov rdi, 1
    jmp exit_program

.err_read_size:
    mov rax, SYS_CLOSE
    mov rdi, r12
    syscall
    mov rsi, err_open_read
    call print_string
    mov rdi, 1
    jmp exit_program

.err_invalid_magic:
    mov rsi, err_magic
    call print_string
    mov rdi, 1
    jmp exit_program

.err_checksum_fail:
    mov rsi, err_checksum
    call print_string
    mov rdi, 1
    jmp exit_program

.err_open_report:
    mov rsi, err_open_write
    call print_string
    mov rdi, 1
    jmp exit_program

; ==============================================================================
; Вспомогательные функции (I/O, строки, числа)
; ==============================================================================

; ------------------------------------------------------------------------------
; print_string: вывод нуль-терминированной строки в stdout
; Вход: RSI = указатель на строку
; ------------------------------------------------------------------------------
print_string:
    push rax
    push rdi
    push rdx
    push rcx

    ; Вычисление длины строки
    xor rdx, rdx
.len_loop:
    cmp byte [rsi + rdx], 0
    je .write
    inc rdx
    jmp .len_loop

.write:
    test rdx, rdx
    jz .done
    mov rax, SYS_WRITE
    mov rdi, STDOUT_FD
    syscall

.done:
    pop rcx
    pop rdx
    pop rdi
    pop rax
    ret

; ------------------------------------------------------------------------------
; print_uint64: печать беззнакового 64-битного числа в десятичном виде
; Вход: RAX = число для печати
; ------------------------------------------------------------------------------
print_uint64:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi

    mov rdi, num_str_buf + 31   ; Начинаем заполнять буфер с конца
    mov byte [rdi], 0           ; Терминатор строки
    mov rbx, 10                 ; Делитель

.convert_loop:
    xor rdx, rdx
    div rbx                     ; rax = rax / 10, rdx = остаток
    add dl, '0'                 ; Преобразование остатка в ASCII символ
    dec rdi
    mov [rdi], dl
    test rax, rax
    jnz .convert_loop

    mov rsi, rdi
    call print_string

    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; ------------------------------------------------------------------------------
; print_int64: печать знакового 64-битного числа
; Вход: RAX = число для печати
; ------------------------------------------------------------------------------
print_int64:
    push rax
    cmp rax, 0
    jge .positive

    ; Если число отрицательное, выводим '-' и инвертируем знак
    push rax
    push rsi
    mov byte [num_str_buf], '-'
    mov byte [num_str_buf + 1], 0
    mov rsi, num_str_buf
    call print_string
    pop rsi
    pop rax

    neg rax

.positive:
    call print_uint64
    pop rax
    ret

; ------------------------------------------------------------------------------
; strcmp: сравнение двух нуль-терминированных строк
; Вход: RDI = str1, RSI = str2
; Выход: EAX = 0 (если равны), != 0 (если не равны)
; ------------------------------------------------------------------------------
strcmp:
    push rcx
    push rdi
    push rsi
.cmp_loop:
    mov al, [rdi]
    mov cl, [rsi]
    cmp al, cl
    jne .not_equal
    test al, al
    jz .equal
    inc rdi
    inc rsi
    jmp .cmp_loop

.equal:
    xor eax, eax
    jmp .done_cmp

.not_equal:
    mov eax, 1

.done_cmp:
    pop rsi
    pop rdi
    pop rcx
    ret

; ------------------------------------------------------------------------------
; exit_program: корректный выход из процесса
; Вход: RDI = код возврата
; ------------------------------------------------------------------------------
exit_program:
    mov rax, SYS_EXIT
    syscall
