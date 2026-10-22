use super::{Session, verify_hero};
use crate::release_screenshots::{
    Error, Result,
    model::{invalid, text},
};
use reqwest::{
    Method,
    blocking::{Client, Response},
};
use serde_json::{Value, json};
use std::{
    collections::BTreeMap,
    fs,
    io::Read,
    net::{Ipv4Addr, SocketAddr},
    path::Path,
    thread,
    time::Duration,
};

impl Session {
    pub(super) fn generate_media(&mut self) -> Result<()> {
        let media = self.work.path().join("media");
        fs::create_dir(&media)?;
        for book in self.fixture.value["books"]
            .as_array()
            .ok_or(Error::Invalid("books"))?
        {
            let folder = text(book, "folder")?;
            let file = text(book, "mediaFile")?;
            fs::create_dir_all(media.join(folder))?;
            let container = format!("bleat-release-media-{}-{}", self.run_id, text(book, "key")?);
            let mount = format!("{}:/audiobooks", media.display());
            let user = format!("{}:{}", unsafe { libc::getuid() }, unsafe {
                libc::getgid()
            });
            let label = format!("bleat.release-screenshot.run={}", self.run_id);
            let duration = book["duration"].to_string();
            let destination = format!("/audiobooks/{folder}/{file}");
            self.media_started = true;
            self.native.status(
                "fixture AAC generation",
                "docker",
                &[
                    "run",
                    "--rm",
                    "--name",
                    &container,
                    "--label",
                    &label,
                    "--user",
                    &user,
                    "--volume",
                    &mount,
                    "--entrypoint",
                    "ffmpeg",
                    &self.config.image,
                    "-hide_banner",
                    "-loglevel",
                    "error",
                    "-f",
                    "lavfi",
                    "-i",
                    "anullsrc=r=16000:cl=mono",
                    "-t",
                    &duration,
                    "-c:a",
                    "aac",
                    "-b:a",
                    "16k",
                    "-movflags",
                    "+faststart",
                    &destination,
                ],
                1200,
            )?;
            let mount = format!("{}:/audiobooks:ro", media.display());
            let container = format!("{container}-probe");
            let measured = self.native.output(
                "fixture AAC duration",
                "docker",
                &[
                    "run",
                    "--rm",
                    "--name",
                    &container,
                    "--label",
                    &label,
                    "--volume",
                    &mount,
                    "--entrypoint",
                    "ffprobe",
                    &self.config.image,
                    "-v",
                    "error",
                    "-show_entries",
                    "format=duration",
                    "-of",
                    "default=nw=1:nk=1",
                    &destination,
                ],
                60,
            )?;
            let measured = measured
                .trim()
                .parse::<f64>()
                .map_err(|_| Error::Invalid("measured AAC duration"))?;
            let expected = book["duration"]
                .as_f64()
                .ok_or(Error::Invalid("fixture duration"))?;
            if !measured.is_finite() || (measured - expected).abs() >= 0.01 {
                return invalid("generated AAC duration differs from fixture");
            }
        }
        Ok(())
    }
    pub(super) fn wait_https(&mut self, port: u16) -> Result<()> {
        let certificate = self.work.path().join("ca.crt");
        for _ in 0..30 {
            self.native.check()?;
            let source = "caddy:/data/caddy/pki/authorities/local/root.crt";
            let mut cmd = self.compose(&["cp", source]);
            cmd.arg(&certificate);
            if self
                .native
                .run("fixture CA availability", &mut cmd, 15, true)
                .is_ok()
                && certificate.is_file()
            {
                let ca = reqwest::Certificate::from_pem(&fs::read(&certificate)?)
                    .map_err(|_| Error::Invalid("fixture CA certificate"))?;
                let host = text(&self.fixture.value["server"], "hostname")?;
                let client = Client::builder()
                    .https_only(true)
                    .no_proxy()
                    .tls_certs_only([ca])
                    .redirect(reqwest::redirect::Policy::none())
                    .resolve(host, SocketAddr::from((Ipv4Addr::LOCALHOST, port)))
                    .timeout(Duration::from_secs(20))
                    .build()
                    .map_err(|_| Error::Http("construct trusted local HTTPS client"))?;
                self.client = Some(client);
                if self
                    .request(Method::GET, "/status", None, None, "fixture readiness")
                    .is_ok()
                {
                    return Ok(());
                }
            }
            thread::sleep(Duration::from_secs(1));
        }
        invalid("Barnyard HTTPS readiness deadline")
    }
    fn response(
        &self,
        method: Method,
        path: &str,
        token: Option<&str>,
        body: Option<Value>,
        label: &'static str,
    ) -> Result<Response> {
        self.native.check()?;
        let client = self
            .client
            .as_ref()
            .ok_or(Error::Invalid("HTTPS client readiness"))?;
        let mut request = client.request(method, format!("{}{path}", self.base_url));
        if let Some(token) = token {
            request = request.bearer_auth(token);
        }
        if let Some(body) = body {
            request = request.json(&body);
        }
        let response = request
            .send()
            .and_then(Response::error_for_status)
            .map_err(|_| Error::Http(label))?;
        self.native.check()?;
        Ok(response)
    }
    fn request(
        &self,
        method: Method,
        path: &str,
        token: Option<&str>,
        body: Option<Value>,
        label: &'static str,
    ) -> Result<Value> {
        let response = self.response(method, path, token, body, label)?;
        let mut data = Vec::new();
        response.take(4 * 1024 * 1024 + 1).read_to_end(&mut data)?;
        if data.len() > 4 * 1024 * 1024 {
            return invalid("fixture HTTP response exceeds limit");
        }
        if data.is_empty() {
            return Ok(Value::Null);
        }
        serde_json::from_slice(&data).map_err(|_| Error::Http(label))
    }
    pub(super) fn initialize(&self) -> Result<String> {
        let status = self.request(Method::GET, "/status", None, None, "server status")?;
        if status["isInit"] == false {
            self.response(Method::POST,"/init",None,Some(json!({"newRoot":{"username":self.fixture.value["account"]["username"],"password":self.password}})),"server initialization")?;
        }
        let status = self.request(Method::GET, "/status", None, None, "initialized status")?;
        if status["isInit"] != true
            || status["serverVersion"] != self.config.profile["serverVersion"]
        {
            return invalid("server initialization/version contract");
        }
        let client = self.client.as_ref().ok_or(Error::Invalid("HTTPS client"))?;
        let response=client.post(format!("{}/login",self.base_url)).header("x-return-tokens","true").json(&json!({"username":self.fixture.value["account"]["username"],"password":self.password})).send().and_then(Response::error_for_status).map_err(|_|Error::Http("native password login"))?;
        let value: Value = response.json().map_err(|_| Error::Http("login response"))?;
        Ok(text(&value["user"], "accessToken")?.to_owned())
    }
    pub(super) fn seed(&self, token: &str) -> Result<()> {
        let libraries = self.request(
            Method::GET,
            "/api/libraries",
            Some(token),
            None,
            "list fixture libraries",
        )?;
        let library_name = text(&self.fixture.value["server"], "libraryName")?;
        let found = libraries["libraries"]
            .as_array()
            .and_then(|a| a.iter().find(|v| v["name"] == library_name));
        let library_id = if let Some(found) = found {
            text(found, "id")?.to_owned()
        } else {
            let created=self.request(Method::POST,"/api/libraries",Some(token),Some(json!({"name":library_name,"folders":[{"fullPath":"/audiobooks"}],"mediaType":"book","provider":"google"})),"create fixture library")?;
            text(&created, "id")?.to_owned()
        };
        self.response(
            Method::POST,
            &format!("/api/libraries/{library_id}/scan"),
            Some(token),
            None,
            "scan fixture library",
        )?;
        let mut items = Value::Null;
        for _ in 0..60 {
            items = self.request(
                Method::GET,
                &format!("/api/libraries/{library_id}/items?limit=50&sort=title&desc=0"),
                Some(token),
                None,
                "scanned fixture books",
            )?;
            if items["total"] == 5 {
                break;
            }
            thread::sleep(Duration::from_secs(1));
        }
        if items["total"] != 5 {
            return invalid("five scanned Barnyard books required");
        }
        let mut ids = BTreeMap::new();
        for book in self.fixture.value["books"]
            .as_array()
            .ok_or(Error::Invalid("books"))?
        {
            let item = items["results"]
                .as_array()
                .and_then(|a| a.iter().find(|v| v["relPath"] == book["folder"]))
                .ok_or(Error::Invalid("scanned fixture book path"))?;
            let id = text(item, "id")?;
            let series = book.get("series").map_or_else(
                || json!([]),
                |s| json!([{"name":s["name"],"sequence":s["sequence"]}]),
            );
            let authors = book["authors"]
                .as_array()
                .ok_or(Error::Invalid("authors"))?
                .iter()
                .map(|name| json!({"name":name}))
                .collect::<Vec<_>>();
            let payload = json!({"metadata":{"title":book["title"],"authors":authors,"narrators":book["narrators"],"series":series,"description":book["description"],"genres":book["genres"]},"tags":book["tags"]});
            self.response(
                Method::PATCH,
                &format!("/api/items/{id}/media"),
                Some(token),
                Some(payload),
                "patch fixture metadata",
            )?;
            self.upload_cover(
                id,
                &self.fixture.directory.join(text(book, "cover")?),
                token,
            )?;
            ids.insert(text(book, "key")?.to_owned(), id.to_owned());
        }
        let hero = ids
            .get("thirteen-hours-of-goat-sounds")
            .ok_or(Error::Invalid("resolved hero"))?;
        let hero_book = self.fixture.value["books"]
            .as_array()
            .and_then(|a| {
                a.iter()
                    .find(|b| b["key"] == "thirteen-hours-of-goat-sounds")
            })
            .ok_or(Error::Invalid("fixture hero"))?;
        self.response(
            Method::POST,
            &format!("/api/items/{hero}/chapters"),
            Some(token),
            Some(json!({"chapters":hero_book["chapters"]})),
            "seed chapters",
        )?;
        for book in self.fixture.value["books"]
            .as_array()
            .ok_or(Error::Invalid("books"))?
        {
            if let Some(progress) = book.get("progress") {
                let id = ids
                    .get(text(book, "key")?)
                    .ok_or(Error::Invalid("resolved progress book"))?;
                let duration = book["duration"]
                    .as_f64()
                    .ok_or(Error::Invalid("duration"))?;
                let time = progress["currentTime"]
                    .as_f64()
                    .ok_or(Error::Invalid("progress"))?;
                self.response(Method::PATCH,&format!("/api/me/progress/{id}"),Some(token),Some(json!({"duration":duration,"currentTime":time,"progress":time/duration,"isFinished":progress["isFinished"],"hideFromContinueListening":false})),"seed progress")?;
            }
        }
        let actual = self.request(
            Method::GET,
            &format!("/api/items/{hero}?expanded=1&include=progress"),
            Some(token),
            None,
            "verify hero metadata",
        )?;
        verify_hero(&actual)?;
        let progress = self.request(
            Method::GET,
            &format!("/api/me/progress/{hero}"),
            Some(token),
            None,
            "verify hero progress",
        )?;
        if progress["currentTime"] != 19800 || progress["isFinished"] != false {
            return invalid("seeded hero progress");
        }
        let session=self.request(Method::POST,&format!("/api/items/{hero}/play"),Some(token),Some(json!({"forceDirectPlay":true,"forceTranscode":false,"mediaPlayer":"AVPlayer","supportedMimeTypes":["audio/mp4","audio/mpeg"],"deviceInfo":{"deviceId":"bleat-release-screenshot-harness","clientName":"Bleat Release Screenshots","clientVersion":"1.0","manufacturer":"Apple","model":"Screenshot Harness"}})),"fixture playback session")?;
        let session_id = text(&session, "id")?;
        let track = session["audioTracks"][0]["index"]
            .as_u64()
            .ok_or(Error::Invalid("playback track index"))?;
        let response = self
            .client
            .as_ref()
            .ok_or(Error::Invalid("HTTPS client"))?
            .get(format!(
                "{}/public/session/{session_id}/track/{track}",
                self.base_url
            ))
            .header("Range", "bytes=0-1023")
            .send()
            .map_err(|_| Error::Http("range playback probe"));
        let _ = self.response(
            Method::POST,
            &format!("/api/session/{session_id}/close"),
            Some(token),
            None,
            "close probe session",
        );
        if response?.status().as_u16() != 206 {
            return invalid("fixture playback range response must be 206");
        }
        Ok(())
    }
    fn upload_cover(&self, id: &str, path: &Path, token: &str) -> Result<()> {
        let boundary = format!("bleat{}", self.run_id);
        let mut data=format!("--{boundary}\r\nContent-Disposition: form-data; name=\"cover\"; filename=\"cover.png\"\r\nContent-Type: image/png\r\n\r\n").into_bytes();
        data.extend(fs::read(path)?);
        data.extend(format!("\r\n--{boundary}--\r\n").as_bytes());
        let response = self
            .client
            .as_ref()
            .ok_or(Error::Invalid("HTTPS client"))?
            .post(format!("{}/api/items/{id}/cover", self.base_url))
            .bearer_auth(token)
            .header(
                "Content-Type",
                format!("multipart/form-data; boundary={boundary}"),
            )
            .body(data)
            .send()
            .and_then(Response::error_for_status)
            .map_err(|_| Error::Http("upload fixture cover"))?;
        let value: Value = response.json().map_err(|_| Error::Http("cover response"))?;
        if value["success"] != true {
            return invalid("cover upload success");
        }
        Ok(())
    }
}
