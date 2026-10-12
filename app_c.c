/**
 * ==============================================================================
 * app_c.c
 * Программа на C для двустороннего бинарного обмена данными с программой на NASM
 *
 * Описание задачи:
 * 1. Программа считывает двоичный файл (bin_exchange/asm_to_c.bin), созданный
 *    низкоуровневой программой на ассемблере NASM.
 * 2. Выполняет строгую проверку двоичных структур:
 *    - Сигнатура заголовка (Magic bytes: "NASM")
 *    - Версия протокола (uint32_t)
 *    - Количество элементов (uint32_t)
 *    - Контрольная сумма чисел int64_t
 * 3. Производит обработку двоичных данных:
 *    - Умножает каждое число на 2 (или производит иную трансформацию)
 *    - Пересчитывает новую общую сумму
 *    - Формирует ответную бинарную структуру с сигнатурой "C_OK"
 * 4. Записывает ответный двоичный файл (bin_exchange/c_to_asm.bin) в папку проекта.
 * 5. Ассемблерная программа затем считывает этот файл и завершает цикл обмена.
 * ==============================================================================
 */

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <errno.h>

#define PACKET_SIZE 64
#define ITEMS_COUNT 5

/**
 * ------------------------------------------------------------------------------
 * Упакованные двоичные структуры (Binary Protocol Structs)
 *
 * Директива #pragma pack(push, 1) отключает автоматическое выравнивание
 * полей компилятором C. Это гарантирует 100% побайтовое соответствие
 * со структурой памяти, заданной в NASM (.data).
 * ------------------------------------------------------------------------------
 */
#pragma pack(push, 1)

/**
 * Структура пакета, получаемого от NASM (64 байта)
 */
typedef struct {
    char     magic[4];           // Сигнатура "NASM" (4 байта)
    uint32_t version;            // Версия протокола (4 байта)
    uint32_t count;              // Количество чисел (4 байта)
    uint32_t reserved;           // Резерв / выравнивание (4 байта)
    int64_t  numbers[ITEMS_COUNT];// Массив 64-битных чисел (5 * 8 = 40 байт)
    uint64_t checksum;           // Контрольная сумма (8 байт)
} PacketFromAsm;

/**
 * Структура пакета, отправляемого обратно в NASM (64 байта)
 */
typedef struct {
    char     magic[4];           // Сигнатура "C_OK" (4 байта)
    uint32_t version;            // Версия протокола (4 байта)
    uint32_t count;              // Количество чисел (4 байта)
    uint32_t status_code;        // Код ответа (например, 200 = OK) (4 байта)
    int64_t  results[ITEMS_COUNT];// Обработанные числа (5 * 8 = 40 байт)
    uint64_t total_sum;          // Сумма обработанных чисел (8 байт)
} PacketFromC;

#pragma pack(pop)

/**
 * Вспомогательная функция: вывод бинарных данных в виде Hex-дампа (шестнадцатеричный вид).
 * Помогает наглядно увидеть реальное байтовое представление пакета в памяти.
 */
static void print_hex_dump(const char *title, const void *data, size_t size) {
    const uint8_t *bytes = (const uint8_t *)data;
    printf("   [HEX DUMP: %s (%zu байт)]\n", title, size);
    for (size_t i = 0; i < size; i++) {
        if (i % 16 == 0) {
            printf("   %04zx: ", i);
        }
        printf("%02x ", bytes[i]);
        if ((i + 1) % 16 == 0 || i + 1 == size) {
            // Выравнивание текстовой колонки, если строка не полная
            if ((i + 1) % 16 != 0) {
                for (size_t pad = 0; pad < 16 - ((i + 1) % 16); pad++) {
                    printf("   ");
                }
            }
            printf(" | ");
            size_t start = i - (i % 16);
            for (size_t j = start; j <= i; j++) {
                uint8_t c = bytes[j];
                printf("%c", (c >= 32 && c <= 126) ? c : '.');
            }
            printf("\n");
        }
    }
    printf("\n");
}

int main(void) {
    const char *input_path  = "bin_exchange/asm_to_c.bin";
    const char *output_path = "bin_exchange/c_to_asm.bin";

    printf("[C]    === ЭТАП 2: Чтение и обработка бинарных данных от NASM ===\n");

    // 1. Открытие бинарного файла от NASM
    // Используем режим "rb" (read binary), чтобы избежать любых трансляций символов
    FILE *fin = fopen(input_path, "rb");
    if (!fin) {
        fprintf(stderr, "[C ОШИБКА] Не удалось открыть входной файл '%s': %s\n",
                input_path, strerror(errno));
        fprintf(stderr, "          Пожалуйста, сначала запустите программу на NASM: ./app_nasm\n\n");
        return 1;
    }

    // 2. Чтение пакета фиксированного размера
    PacketFromAsm in_packet;
    memset(&in_packet, 0, sizeof(in_packet));

    size_t read_bytes = fread(&in_packet, 1, sizeof(in_packet), fin);
    fclose(fin);

    if (read_bytes != sizeof(PacketFromAsm)) {
        fprintf(stderr, "[C ОШИБКА] Прочитано %zu байт вместо ожидаемых %zu!\n",
                read_bytes, sizeof(PacketFromAsm));
        return 1;
    }

    printf("[C]    Успешно прочитано %zu байт из '%s'.\n", read_bytes, input_path);

    // Выводим полученный шестнадцатеричный дамп для наглядности
    print_hex_dump("Входной бинарный пакет от NASM", &in_packet, sizeof(in_packet));

    // 3. Валидация сигнатуры magic ("NASM")
    if (memcmp(in_packet.magic, "NASM", 4) != 0) {
        fprintf(stderr, "[C ОШИБКА] Неверная сигнатура magic: '%.4s' (ожидалось 'NASM')!\n",
                in_packet.magic);
        return 1;
    }
    printf("[C]    Сигнатура 'NASM' валидна. Версия протокола: %u.\n", in_packet.version);

    if (in_packet.count != ITEMS_COUNT) {
        fprintf(stderr, "[C ОШИБКА] Неверное количество элементов: %u (ожидалось %d)!\n",
                in_packet.count, ITEMS_COUNT);
        return 1;
    }

    // 4. Проверка контрольной суммы исходного пакета
    uint64_t calculated_sum = 0;
    printf("[C]    Исходные числа из бинарного пакета NASM:\n");
    for (int i = 0; i < ITEMS_COUNT; i++) {
        printf("       - numbers[%d] = %ld\n", i, (long)in_packet.numbers[i]);
        calculated_sum += (uint64_t)in_packet.numbers[i];
    }

    printf("[C]    Заявленная сумма NASM: %lu, Рассчитанная C: %lu\n",
           (unsigned long)in_packet.checksum, (unsigned long)calculated_sum);

    if (calculated_sum != in_packet.checksum) {
        fprintf(stderr, "[C ОШИБКА] Контрольная сумма не совпадает!\n");
        return 1;
    }
    printf("[C]    Контрольная сумма успешно верифицирована!\n\n");

    // 5. Обработка данных и формирование ответного пакета PacketFromC
    PacketFromC out_packet;
    memset(&out_packet, 0, sizeof(out_packet));

    memcpy(out_packet.magic, "C_OK", 4);
    out_packet.version     = 1;
    out_packet.count       = ITEMS_COUNT;
    out_packet.status_code = 200; // Статус: Успешно (HTTP-like 200 OK)

    printf("[C]    Выполняем обработку данных (умножение на 2):\n");
    uint64_t new_total_sum = 0;
    for (int i = 0; i < ITEMS_COUNT; i++) {
        // Трансформация: умножаем каждое число на 2
        out_packet.results[i] = in_packet.numbers[i] * 2;
        new_total_sum += (uint64_t)out_packet.results[i];
        printf("       - results[%d] = %ld (было %ld)\n",
               i, (long)out_packet.results[i], (long)in_packet.numbers[i]);
    }
    out_packet.total_sum = new_total_sum;
    printf("[C]    Новая итоговая сумма: %lu\n\n", (unsigned long)new_total_sum);

    // 6. Вывод шестнадцатеричного дампа формируемого ответа
    print_hex_dump("Выходной бинарный пакет от C", &out_packet, sizeof(out_packet));

    // 7. Запись ответного двоичного файла
    // Используем режим "wb" (write binary)
    FILE *fout = fopen(output_path, "wb");
    if (!fout) {
        fprintf(stderr, "[C ОШИБКА] Не удалось создать файл '%s': %s\n",
                output_path, strerror(errno));
        return 1;
    }

    size_t written_bytes = fwrite(&out_packet, 1, sizeof(out_packet), fout);
    fclose(fout);

    if (written_bytes != sizeof(PacketFromC)) {
        fprintf(stderr, "[C ОШИБКА] Записано только %zu байт из %zu!\n",
                written_bytes, sizeof(PacketFromC));
        return 1;
    }

    printf("[C]    Успешно записан бинарный файл: '%s' (%zu байт).\n",
           output_path, written_bytes);
    printf("[C]    Теперь запустите программу на NASM для финальной верификации: ./app_nasm\n\n");

    return 0;
}
