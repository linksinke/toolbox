# -*- coding: utf-8 -*-

"""
Excel 合并单元格解除工具
自动解除 Excel 文件中所有合并单元格，并将原合并区域的每个单元格填充为相同的值，结果保存为新文件，不覆盖原文件。
"""
import os
import openpyxl as px


def unmerge_and_fill_cells(file_path):
    """
    解除 Excel 文件中所有合并单元格，并将原合并区域填充为相同的值，
    结果保存为新文件（原文件名加 _output 后缀）。

    :param file_path: 输入的 Excel 文件路径
    """
    if not os.path.exists(file_path):
        print(f'文件不存在: {file_path}')
        return

    # 加载失败时给出明确提示，不继续处理或生成输出文件。
    try:
        workbook = px.load_workbook(file_path)
    except PermissionError as exc:
        print(f'无法读取文件，请检查访问权限或文件是否被其他程序独占: {file_path}\n详情: {exc}')
        return
    except OSError as exc:
        print(f'读取文件失败，请检查路径、文件是否存在及磁盘状态: {file_path}\n详情: {exc}')
        return
    except Exception as exc:
        # 损坏的 ZIP、工作簿 XML 或不支持的格式可能触发不同异常。
        print(f'加载 Excel 失败，文件可能损坏或格式不受支持: {file_path}\n详情: {exc}')
        return

    try:
        for sheet in workbook.worksheets:
            # 转换为列表，避免迭代时修改原集合
            merged_ranges = list(sheet.merged_cells.ranges)

            for merged_range in merged_ranges:
                min_row = merged_range.min_row
                min_col = merged_range.min_col
                max_row = merged_range.max_row
                max_col = merged_range.max_col

                # 合并单元格的值始终存储在左上角单元格
                fill_value = sheet.cell(row=min_row, column=min_col).value

                # 解除合并
                sheet.unmerge_cells(str(merged_range))

                # 将原合并区域的每个单元格填充为相同的值
                for row in range(min_row, max_row + 1):
                    for col in range(min_col, max_col + 1):
                        sheet.cell(row=row, column=col, value=fill_value)

            print(f'工作表 "{sheet.title}" 处理完成，共解除 {len(merged_ranges)} 个合并区域')

        # 生成输出文件路径：原文件名 + _output + 原扩展名
        base, ext = os.path.splitext(file_path)
        output_file_path = f'{base}_output{ext}'
        try:
            workbook.save(output_file_path)
        except PermissionError as exc:
            print(f'无法保存文件，请关闭占用该文件的 Excel/其他程序，并检查目录写入权限: {output_file_path}\n详情: {exc}')
            return
        except OSError as exc:
            print(f'保存文件失败，请检查磁盘空间及输出目录是否可用: {output_file_path}\n详情: {exc}')
            return
        except Exception as exc:
            print(f'保存 Excel 失败，请检查工作簿内容: {output_file_path}\n详情: {exc}')
            return
        print(f'输出文件已保存至: {output_file_path}')
    finally:
        # 正常结束、保存失败或处理中断时都释放工作簿资源。
        workbook.close()


if __name__ == '__main__':
    input_file_path = 'input.xlsx'
    unmerge_and_fill_cells(input_file_path)
