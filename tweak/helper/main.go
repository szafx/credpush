// credpush-helper —— 让 creddaemon **自己**把会话推到面板（不切 App）
//
// 由 creddaemon.sh 在发现新会话时调用：
//     credpush-helper --container <中国移动容器路径> --id <容器id>
// 退出码 0 = 推送成功（daemon 本轮不再 uiopen）；非 0 = 失败（daemon 回退 uiopen）。
//
// 为什么需要它：这台手机**没有任何 HTTPS 客户端**（没有 curl/wget/python/openssl CLI），
// bash 的 /dev/tcp 只能发裸 TCP，推不了 HTTPS。所以用一个 Go 静态二进制来做。
//
// 它做的事：
//   1. 解析 <container>/Library/Cookies/Cookies.binarycookies（结构化二进制，带创建时间）
//   2. 取出 10086 域的 JSESSIONID / UID / Comment / ticketID，**按 cookie 创建时间挑最新的一组**
//   3. 去重交给 daemon（triggered.txt / hint），这里不重复推
//   4. POST /api/cred/push（带 X-Cred-Token）
//
// 注意：必须放在 /var/jb/usr/libexec/（不要 /usr/local/bin —— roothide 会往那里注入，
//       旧的编译版 daemon 就是因此在 main 之前卡死）。
package main

import (
	"bytes"
	"encoding/binary"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"math"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"
)

type cookie struct {
	Domain  string
	Name    string
	Path    string
	Value   string
	Created float64
}

func cstr(rec []byte, off int) string {
	if off <= 0 || off >= len(rec) {
		return ""
	}
	i := bytes.IndexByte(rec[off:], 0)
	if i < 0 {
		return ""
	}
	return string(rec[off : off+i])
}

// parseBinaryCookies 解析 iOS 的 Cookies.binarycookies
func parseBinaryCookies(path string) ([]cookie, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	if len(b) < 8 || string(b[:4]) != "cook" {
		return nil, fmt.Errorf("不是 binarycookies 格式")
	}
	n := int(binary.BigEndian.Uint32(b[4:8]))
	if n <= 0 || n > 1000 {
		return nil, fmt.Errorf("页数异常: %d", n)
	}
	off := 8
	sizes := make([]int, 0, n)
	for i := 0; i < n; i++ {
		if off+4 > len(b) {
			return nil, fmt.Errorf("截断")
		}
		sizes = append(sizes, int(binary.BigEndian.Uint32(b[off:off+4])))
		off += 4
	}
	var out []cookie
	for _, sz := range sizes {
		if sz <= 0 || off+sz > len(b) {
			break
		}
		page := b[off : off+sz]
		off += sz
		if len(page) < 8 {
			continue
		}
		cnt := int(binary.LittleEndian.Uint32(page[4:8]))
		for i := 0; i < cnt; i++ {
			p := 8 + 4*i
			if p+4 > len(page) {
				break
			}
			co := int(binary.LittleEndian.Uint32(page[p : p+4]))
			if co < 0 || co+56 > len(page) {
				continue
			}
			rec := page[co:]
			recSize := int(binary.LittleEndian.Uint32(rec[0:4]))
			if recSize > len(rec) {
				recSize = len(rec)
			}
			rec = rec[:recSize]
			if len(rec) < 56 {
				continue
			}
			doff := int(binary.LittleEndian.Uint32(rec[16:20]))
			noff := int(binary.LittleEndian.Uint32(rec[20:24]))
			poff := int(binary.LittleEndian.Uint32(rec[24:28]))
			voff := int(binary.LittleEndian.Uint32(rec[28:32]))
			cre := math.Float64frombits(binary.LittleEndian.Uint64(rec[48:56]))
			out = append(out, cookie{
				Domain: cstr(rec, doff), Name: cstr(rec, noff),
				Path: cstr(rec, poff), Value: cstr(rec, voff), Created: cre,
			})
		}
	}
	return out, nil
}

// newest 返回某名字里创建时间最新的那条
func newest(cs []cookie, name string) (string, float64) {
	best, ts := "", -1.0
	for _, c := range cs {
		if c.Name == name && c.Value != "" && c.Created >= ts {
			best, ts = c.Value, c.Created
		}
	}
	return best, ts
}

func main() {
	container := flag.String("container", "", "中国移动容器路径")
	cid := flag.String("id", "", "容器 id（日志用）")
	server := flag.String("server", "", "面板地址（默认取 CREDD_PUSH_URL 或 https://ydhf.szafx.icu）")
	tokenFile := flag.String("token-file", "/var/mobile/Library/CredDaemon/cred_push.token", "推送令牌文件")
	dry := flag.Bool("dry", false, "只打印，不真推")
	force := flag.Bool("force", false, "跳过 UID 去重")
	flag.Parse()

	if *server == "" {
		*server = os.Getenv("CREDD_PUSH_URL")
	}
	if *server == "" {
		*server = "https://ydhf.szafx.icu"
	}
	*server = strings.TrimRight(*server, "/")

	if *container == "" {
		fmt.Println("缺 --container")
		os.Exit(2)
	}
	cf := filepath.Join(*container, "Library", "Cookies", "Cookies.binarycookies")
	cs, err := parseBinaryCookies(cf)
	if err != nil {
		fmt.Printf("读 cookies 失败: %v\n", err)
		os.Exit(3)
	}
	// 只看 10086 域的
	var mine []cookie
	for _, c := range cs {
		if strings.Contains(c.Domain, "10086") {
			mine = append(mine, c)
		}
	}
	sid, sidTS := newest(mine, "JSESSIONID")
	uid, _ := newest(mine, "UID")
	ticket, _ := newest(mine, "ticketID")
	comment, _ := newest(mine, "Comment")
	if sid == "" || uid == "" || ticket == "" {
		fmt.Printf("会话不完整（sid=%v uid=%v ticket=%v）\n", sid != "", uid != "", ticket != "")
		os.Exit(4)
	}
	if comment == "" {
		comment = "SessionServer-unity"
	}
	sess := fmt.Sprintf("JSESSIONID=%s; UID=%s; Comment=%s; ticketID=%s;", sid, uid, comment, ticket)
	fmt.Printf("容器=%s sid=%s… uid=%s… ticket=%s 创建=%s\n", short(*cid, 8), short(sid, 8),
		short(uid, 8), ticket, tsStr(sidTS))

	token := ""
	if b, err := os.ReadFile(*tokenFile); err == nil {
		token = strings.TrimSpace(string(b))
	}
	if token == "" && !*dry {
		fmt.Println("没有推送令牌文件:", *tokenFile)
		os.Exit(5)
	}

	cli := &http.Client{Timeout: 20 * time.Second}

	// 去重交给 daemon 的 triggered.txt / hint（这里不重复实现）
	_ = force

	body, _ := json.Marshal(map[string]any{"sessions": []string{sess}})
	if *dry {
		fmt.Println("DRY 会推:", sess[:24]+"…", "->", *server+"/api/cred/push")
		os.Exit(0)
	}
	req, _ := http.NewRequest("POST", *server+"/api/cred/push", bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-Cred-Token", token)
	resp, err := cli.Do(req)
	if err != nil {
		fmt.Println("推送请求失败:", err)
		os.Exit(6)
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(resp.Body)
	fmt.Printf("HTTP %d %s\n", resp.StatusCode, short(string(raw), 300))
	if resp.StatusCode != 200 {
		os.Exit(7)
	}
	var out struct {
		OK    bool `json:"ok"`
		Items []struct {
			OK  bool   `json:"ok"`
			Msg string `json:"msg"`
		} `json:"items"`
	}
	if err := json.Unmarshal(raw, &out); err != nil || !out.OK {
		os.Exit(8)
	}
	for _, it := range out.Items {
		if it.OK {
			fmt.Println("✓ 推送成功")
			os.Exit(0)
		}
	}
	fmt.Println("服务端没有接受这条会话")
	os.Exit(9)
}

func short(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n]
}

func tsStr(t float64) string {
	if t <= 0 {
		return "-"
	}
	return time.Unix(int64(t), 0).Format("01-02 15:04:05")
}
