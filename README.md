# TextFSM Ruby

使用 Ruby 实现的模板驱动文本解析状态机。读取 TextFSM 模板和半结构化文本，输出二维数组或 Hash 数组，适合解析网络设备 CLI 输出、系统命令输出等。

解析语义参考 [Google TextFSM 2.1.0](https://github.com/google/textfsm/tree/f80bbb459c55ff5f21651e48d2529722d667af97)，运行时使用 Ruby 自身的正则引擎，不需要 Python 或外部进程；运行时依赖 Ruby 标准库 gem `json`、`optparse` 和 `strscan`。要求 Ruby 3.1 或以上。

0.2 使用 `TextFSM` 模块组织 `Parser`、`Field`、`Rule`、`Table` 和 `CliTable`；公开方法与选项扩展接口按 Ruby 风格重新设计，不保留 0.1 的接口别名。

## 安装

在项目的 `Gemfile` 中添加：

```ruby
gem "textfsm"
```

然后运行 `bundle install`。也可以直接安装命令行工具：

```sh
gem install textfsm
```

开发时可使用本地路径：

```ruby
gem "textfsm", path: "/path/to/textfsm"
```

也可以构建并安装：

```sh
bundle install
bundle exec rake build
gem install ./pkg/textfsm-0.2.2.gem
```

源码仓库：[gatework/textfsm](https://github.com/gatework/textfsm)。

## 快速使用

```ruby
require "textfsm"

template = <<~'FSM'
  Value Required INTERFACE (\S+)
  Value ADDRESS (\S+)
  Value STATUS (up|down|administratively down)
  Value PROTOCOL (up|down)

  Start
    ^${INTERFACE}\s+${ADDRESS}\s+${STATUS}\s+${PROTOCOL}$$ -> Record
FSM

text = <<~TEXT
  GigabitEthernet0/0 192.0.2.2 up up
  GigabitEthernet0/1 unassigned administratively down down
TEXT

fsm = TextFSM::Parser.new(template)
p fsm.header
# => ["INTERFACE", "ADDRESS", "STATUS", "PROTOCOL"]
p fsm.parse(text)
# => [["GigabitEthernet0/0", "192.0.2.2", "up", "up"],
#     ["GigabitEthernet0/1", "unassigned", "administratively down", "down"]]

fsm.reset
p fsm.parse_hashes(text)
# => [{"INTERFACE"=>"GigabitEthernet0/0", "ADDRESS"=>"192.0.2.2",
#      "STATUS"=>"up", "PROTOCOL"=>"up"}, ...]
```

模板使用单引号 heredoc（`<<~'FSM'`），避免 Ruby 提前处理正则中的反斜杠。`TextFSM::Parser.new` 的字符串参数是**模板内容**；从文件读取请用 `TextFSM::Parser.from_file("template.textfsm")`，也可以传入已打开的文件或 `StringIO`。IO 从当前位置读取并保持在读完的位置，不会自动 `rewind`。

## 模板语法

模板先声明连续的 `Value`，用空行分隔状态。初始状态必须叫 `Start`。状态之间用空行分隔；规则以一个空格、两个空格或一个制表符缩进，随后必须是 `^`。以 `#` 开始的注释行会被忽略。

```text
Value [选项,选项] NAME (正则表达式)

Start
  ^匹配规则 -> 行操作.记录操作 下一个状态
```

规则中的 `$NAME` 或 `${NAME}` 会替换为对应字段的捕获组。规则需要正则行尾锚点 `$` 时写 `$$`；需要匹配字面量美元符号时写 `\$$`。字段名和状态名最长 48 个字符。

字段选项：

| 选项 | 行为 |
| --- | --- |
| `Required` | 字段为空时丢弃当前记录 |
| `Filldown` | 保存字段值，后续记录沿用，直到重新赋值或 `Clearall` |
| `Fillup` | 新值向上填充此前连续的空字段，遇到非空值停止 |
| `List` | 将多次匹配累积为数组 |
| `Key` | 标记多模板表合并所使用的键 |

选项按照声明顺序执行，保留 Python 的顺序语义，例如 `List,Required` 与 `Required,List` 在可选匹配或空值时可能有不同结果。

行操作和记录操作可以省略；默认是 `Next.NoRecord`：

| 操作 | 行为 |
| --- | --- |
| `Next` | 消耗当前行，从当前或目标状态的第一条规则处理下一行 |
| `Continue` | 保留当前行，继续当前状态的下一条规则；不能同时指定目标状态 |
| `Error ["消息"]` | 抛出 `TextFSM::ParseError`，包含模板规则行号和输入行 |
| `NoRecord` | 保留当前字段，不输出记录 |
| `Record` | 输出符合条件的记录，清除普通字段，保留 `Filldown` |
| `Clear` | 清除普通字段，保留 `Filldown` |
| `Clearall` | 清除全部字段，包括 `Filldown` 和列表缓存 |

记录操作先于行操作执行。未匹配的行会被跳过，可添加 `^.* -> Error "Unexpected input"` 拒绝未识别的输入。缺失的普通字段输出 `""`，未匹配的列表输出 `[]`；纯未赋值的记录不会输出，实际匹配到的空字符串可以输出。

输入结束时默认执行一次 `Record`。定义空的 `EOF` 状态可以关闭这一行为。跳转到 `End` 会停止解析并跳过最终记录；需要保留当前记录时使用 `Record End`。`EOF` 和 `End` 的显式状态定义必须为空。

`Filldown` 本身也会让最终记录非空，因此可能产生尾部记录。通常给每条业务记录的标识字段设置 `Required`，或根据模板含义定义空 `EOF`。

### 列表中的结构化数据

`List` 字段包含 Python 风格的命名子捕获组时，每次匹配会产生一个 Hash：

```text
Value List PERSON ((?P<name>\w+)\s+(?P<age>\d+))

Start
  ^${PERSON}
```

解析 `Bob 32\nAlice 27\n` 后得到：

```ruby
[[[{ "name" => "Bob", "age" => "32" }, { "name" => "Alice", "age" => "27" }]]]
```

所有捕获值保持字符串；可选命名子组未匹配时为 `nil`。同一条规则里不能出现重复的命名捕获组，包括重复引用同一个 Value。

## 分段解析与复用

```ruby
fsm = TextFSM::Parser.from_file("template.textfsm")
fsm.parse(first_chunk, eof: false)
rows = fsm.parse(last_chunk)

fsm.reset
rows = fsm.parse(another_command_output)
```

`parse` 和 `rows` 返回累计结果的深度冻结快照；它们不会自动重置解析器。需要可修改的数据时使用 `to_a`、`to_hashes` 或 `parse_hashes`，这些接口返回独立的深拷贝。分段必须按完整行切分，`eof: false` 仅抑制最终 `Record`，不缓存半行。`parse` 也接受可读取的 IO，但会一次读取内容。不同设备输出应先 `reset` 或使用新实例；有状态的实例不应由多个线程并发共享。`Fillup` 会更新解析器内部的历史行；此前返回的快照不变，后续 `parse`／`rows` 会包含回填后的结果。

可用接口：`header`、`rows`、`current_state`、`states`、`state_names`、`fields_with_option("Key")`、`to_a`、`to_hashes`、`to_s`（重建去除注释的模板）。表头、状态规则及编译后的模式只读；字段的运行时状态保留在解析器内部。`fields_with_option` 也接受 `:Key` 等 Symbol。

## 根据设备与命令选择模板

`CliTable` 读取与 Python TextFSM 相同的 index 文件格式：

```ruby
require "textfsm/cli_table"

table = TextFSM::CliTable.new(index: "index", template_dir: "/path/to/templates")
table.parse(output, attributes: { "Vendor" => "Cisco", "Command" => "sh ver" })
p table.header
p table.to_a
p table.to_hashes
```

index 示例：

```text
Template, Vendor, Command
cisco_version_template, Cisco, sh[[ow]] ve[[rsion]]
```

按文件顺序选择第一条匹配记录；匹配从属性字符串开头开始，空单元格是通配条件，index 未定义的属性会被忽略。`Command` 中 `sh[[ow]]` 支持 `sh`、`sho`、`show`。index 遵循上游简单逗号分隔格式，不处理带引号的 CSV 字段。

可绕过 index 显式传入模板：

```ruby
table = TextFSM::CliTable.new(template_dir: "/path/to/templates")
table.parse(output, templates: "first.textfsm:second.textfsm")
# templates 也接受文件名数组。
```

多个模板重复解析同一份输入，只合入新增列。有 `Key` 时按键匹配首条记录，否则按行位置合并。保留第一张表的行数，缺少匹配的新增列填 `""`。表格支持 Enumerable，行号从零开始。`IndexTable#match(attributes)` 返回首条匹配的只读 Hash，未命中返回 `nil`，无需换算行号。

`Table#merge(other, keys: ["ID"])` 返回合入新列的新表，保留原表；`merge!` 更新当前表并返回自身。新表保留接收者的类型，因此 `CliTable#merge` 也保留索引、输入和键。表头和 `rows`／`table[index]` 只读；`to_a` 和 `to_hashes` 返回独立副本，嵌套的列表与 Hash 也不会共享可变数据。构造表格时拒绝重复列名和宽度不一致的行。

`CliTable#keys` 返回模板声明的键，使用 `table.keys = ["ID"]` 显式设置，或 `table.keys += ["NAME"]` 增补。`key_for(row)` 返回键值数组，没有键时返回 `[]`。排序遵循 Ruby 自身的比较规则：

```ruby
table.sort!                                      # 按行比较
table.sort_by! { |row| table.key_for(row) }        # 按声明的键排序
table.sort_by! { |row| row[0].to_i }               # 明确按数值排序
table.sort! { |left, right| right <=> left }       # 倒序
```

`load_index("another_index")` 可替换索引。多模板解析、合并或索引加载失败时保留上次成功的表头、数据、键及输入。

## 命令行

```sh
# 本地源码运行；安装 gem 后可直接使用 textfsm 命令
ruby exe/textfsm examples/cisco_version_template examples/cisco_version_example
cat examples/cisco_version_example | ruby exe/textfsm examples/cisco_version_template
ruby exe/textfsm --rows examples/cisco_version_template examples/cisco_version_example
ruby exe/textfsm --format table examples/cisco_version_template examples/cisco_version_example
ruby exe/textfsm --validate examples/cisco_version_template
```

默认输出 JSON 对象数组；`--rows` 输出包含 `header` 和 `rows` 的 JSON；`--format table` 输出制表符分隔的可读表格。成功退出码为 `0`，参数、文件、模板或解析错误为 `2`。`--validate` 只验证模板，不读取标准输入。

## 扩展字段选项

```ruby
class Uppercase < TextFSM::Options::Base
  def after_assign
    field.value = field.value&.upcase
  end
end

parser = TextFSM::Parser.new(template, options: { "Uppercase" => Uppercase })
```

模板中可以声明 `Value Uppercase NAME (...)`。显式传入的选项与五种内置选项合并，只对该解析器生效；内置注册表不可修改。选项类必须继承 `TextFSM::Options::Base`。

可实现 `after_initialize`、`after_assign`、`after_clear`、`after_reset`、`before_record` 钩子，通过 `field.value` 读写当前值。在 `before_record` 中执行 `throw :skip_record` 可以丢弃当前记录；字段仍会按正常规则清除。选项的 `visible?` 返回 `false` 可以隐藏字段，输出列在模板加载时确定，`Fillup` 使用同一份列映射。隐藏字段仍执行选项钩子，可用于控制记录是否输出。

## 工程约定

- `lib/textfsm.rb` 是统一入口，各组件也可单独 `require "textfsm/parser"`、`require "textfsm/pattern"` 等。CLI 位于 `exe/textfsm`。
- `exe/` 遵循 Bundler 的 gem 可执行文件约定，存放安装给使用者的命令；`script/` 存放项目维护脚本。`Gemfile.lock` 纳入 Git，固定开发和发布验证使用的依赖，不会打进 gem；gemspec 中的运行时依赖仅声明最低版本，不限制主版本。
- 类和模块使用 `CamelCase`，方法、参数和实例变量使用 `snake_case`；查询使用 `?`，属性赋值使用 `=`。类方法写成 `def self.method_name`，解析状态属于实例，固定映射使用冻结常量。
- 集合通过 `Enumerable`、`each`、`[]`、`size` 和 `empty?` 提供 Ruby 接口；需要代码块的迭代方法在未传块时返回 `Enumerator`。`merge`／`merge!` 区分创建新表和修改当前表，排序复用 Ruby 比较器。
- 数据转换使用 `map`、`filter_map`、`transform_values`、`reduce` 等集合方法；简单转换使用单行 `{ ... }`，多行逻辑和有副作用的迭代使用 `do ... end`。简短取值使用条件表达式，复杂状态分支使用 `if`／`case`。
- 构造方法组织对象初始化，声明解析等细节放入私有方法。字段选项通过明确的生命周期钩子扩展；错误使用 `TextFSM::Error` 的子类，预期的跳过记录使用 `catch`／`throw`。
- 内部动作使用 Symbol，省略目标状态使用 `nil`；模板文本继续使用标准的 `Next`、`Record`、`Clearall` 等语法。
- 正则编译使用 `StringScanner`，编译器的游标和分组栈不保留在最终 `Pattern` 对象中。模式始终从输入开头匹配。
- `bundle exec rake` 执行 Minitest 和 RuboCop；`rake test`、`rake lint` 可分别运行。代码规则见 `.rubocop.yml`。
- `bundle exec rake verify` 进一步构建 gem，从 `bundle install` 准备的本地缓存离线安装运行时依赖和候选包；安装环境仅使用临时目录的 gem 与 Ruby 自带的默认 gem。逐文件核对源码内容，并验证独立加载与 CLI 输出、标准输入和退出码，避免开发依赖掩盖缺失的运行时依赖。生成的包位于 `pkg/`，不会发布到 RubyGems。

## 发布到 RubyGems

发布使用标签触发的 OIDC Trusted Publishing，不保存长期 API key。完整 Ruby CI 矩阵通过后，
工作流验证并上传同次 CI 的 gem，再核对 RubyGems 下载和 GitHub Release 的 SHA256。
流程、账号绑定及失败恢复见 [发布说明](docs/RELEASING.md)。

本地预检可执行 `bundle exec ruby script/release.rb --dry-run --artifact pkg/textfsm-0.2.2.gem`；
已有产物路径不会重新构建。更新版本及 CHANGELOG、提交并确认远端 CI 后推送对应版本标签。

## 兼容范围与验证

本项目实现 TextFSM 模板解析、状态机、全部五种内置字段选项、列表命名子组、字典输出，以及命令索引与多模板表合并。官方示例保存在 `examples/`。

Ruby 使用 Onigmo 正则引擎。本项目转换 Python 命名组 `(?P<name>...)`、命名与数字反向引用、贪婪／懒惰／占有量词、常用内联标志 `i/m/s/x/a/u`、Unicode 字符类及锚点语义。**这不是完整 Python `re` 引擎的替代实现**：Unicode 名称转义 `\N{...}`、条件组等不支持的扩展会报 `TemplateError`；两种引擎的大小写折叠、复杂后行断言等细节仍可能不同。使用额外模板库时，应以实际模板与输入执行对照测试。

Ruby 的 `End` / `EOF` 跳转在后续调用中继续保持终止状态，重新解析需 `reset`；不会复现 Python 在后续调用中再次处理一行的边界行为。CLI JSON 格式和错误文案采用 Ruby 接口；未移植 Python `terminal` 的终端控制功能或 `texttable` 的完整展示/编辑 API。模板 IO 不自动回卷；结果采用快照语义；输入必须是字符串或可读取的 IO。

运行测试：

```sh
bundle install
bundle exec rake
```

测试包含单元测试及离线 Python 对照数据，正常运行无需 Python 或网络。`test/fixtures/python_conformance.json` 来自固定上游提交的 33 项原测试、8 个官方示例，以及 140 组确定性的选项/状态组合场景，共 203 组实例轨迹。对照校验表头、模板重建、选项元数据、累计结果、重置和目标状态。CI 覆盖 Ruby 3.1、3.2、3.3、3.4 和 4.0，每个版本执行 `rake verify`。额外回归覆盖结果隔离、自定义选项、隐藏列回填、索引事务、CLI 错误和正则语法边界。

需要重新生成对照数据时：

```sh
git clone https://github.com/google/textfsm.git /tmp/google-textfsm
git -C /tmp/google-textfsm checkout f80bbb459c55ff5f21651e48d2529722d667af97
python3 script/generate_conformance.py /tmp/google-textfsm
bundle exec rake
```

## 许可证

Apache-2.0。原项目归属、参考版本及复制文件说明见 [NOTICE](NOTICE)，许可证全文见 [LICENSE](LICENSE)。
