import vibe.vibe;
import vibe.stream.tls;
import vibe.data.json;
import vibe.db.postgresql;
import std.string;
import std.typecons;
import std.file;
import std.random;

// TODO: перенести в ini-файл
immutable string botName = "vonneybot";
immutable string tgWebhookUrl = "/vonneybot";
immutable string dbName = "vonneybot";
immutable string dbUserName = "f";
immutable string tApiUrl = "https://api.telegram.org/";
string tApiToken;

PostgresClient client;

void main()
{
	auto settings = new HTTPServerSettings;
	/// Порт, на котором слушает бот
	settings.port = 8082;
	/// Адреса интерфейсов, на которых слушает бот
	settings.bindAddresses = ["::1", "127.0.0.1"];

	auto router = new URLRouter;
	router.get("/", &index);
	router.get("/auth", &auth);
	router.get(tgWebhookUrl, &tgWebhookDispatcher);
	router.post(tgWebhookUrl, &tgWebhookDispatcher);
	router.get("*", serveStaticFiles("./public/"));
	listenHTTP(settings, router);

	client = new PostgresClient("dbname=" ~ dbName ~ " user=" ~ dbUserName, 4);

	auto conn = client.lockConnection();
	immutable qtApiToken = conn.execStatement("select value from settings where name = 'tApiToken';",
		ValueFormat.BINARY);
	destroy(conn);
//	debug { logInfo("qtApiToken:\n" ~ qtApiToken.toString); }
	auto qtApiTokenAnswer = qtApiToken.getAnswer;
	if(qtApiTokenAnswer.length > 0)
	{
		debug { logInfo("inMain qtApiTokenAnswer"); }
		debug { logInfo("(privatized) qtApiToken[0][0] = " ~ qtApiToken[0][0].toString.split("::")[0].strip("\"").split(":")[0] ~ ":<SECRET>"); }
		tApiToken = tApiUrl ~ qtApiToken[0][0].toString.split("::")[0].strip("\"");
	}
	else
	{
		logInfo("Value 'tApiToken' not found in table 'settings' of database '" ~ dbName ~ "', exiting");
		return;
	}

	logInfo("Running on http://[::1]:" ~ to!string(settings.port) ~ "/");
	runApplication();
}

/**
Обработчик главной страницы сайта
*/
void index(HTTPServerRequest req, HTTPServerResponse res)
{
	res.writeBody("VOID");
}

/**
Обработчик страницы авторизации сайта
*/
void auth(HTTPServerRequest req, HTTPServerResponse res)
{
	render!("auth.dt")(res);
}

/**
Функция отправки сообщения в Telegram
*/
Json tgSend(string query)
{
	Json result;
	debug { logInfo("tgSend"); }
	requestHTTP(tApiToken ~ "/",
		(scope HTTPClientRequest req) {
			req.method = HTTPMethod.POST;
			req.writeBody(cast(ubyte[])query, "application/json");
		},
		(scope HTTPClientResponse res) {

			result = res.readJson;
		}
	);
	debug { logInfo("tgSend res:\n" ~ to!string(result)); }
	return result;
}

/**
Функция формирования сообщения для Telegram с использованием id чата из запроса
*/
bool createMessageForChat(Json cmReq, string cmMsg, out string cmRes)
{
	debug { logInfo("createMessageForChat(Json cmReq ...)"); }
	if("message" in cmReq) if("chat" in cmReq["message"]) if("id" in cmReq["message"]["chat"])
	{
		debug { logInfo("createMessageForChat inJsonOk"); }
		debug { logInfo("createMessageForChat cmReq.message.chat.id = " ~ to!string(cmReq["message"]["chat"]["id"])); }
		cmRes = q"[{"method":"sendMessage","parse_mode":"Markdown","chat_id":]"
			~ to!string(cmReq["message"]["chat"]["id"])
                        ~ q"[,"text":"]" ~ cmMsg ~ q"["}]";
		return true;
	}
	debug { logInfo("createMessageForChat inJsonNotOk"); }
	return false;
}

/**
Функция формирования сообщения для Telegram с использованием id чата в виде целого числа
*/
bool createMessageForChat(long chat_id, string cmMsg, out string cmRes)
{
	debug { logInfo("createMessageForChat(long chat_id ...)"); }
	cmRes = q"[{"method":"sendMessage","parse_mode":"Markdown","chat_id":]"
		~ to!string(chat_id)
                       ~ q"[,"text":"]" ~ cmMsg ~ q"["}]";
	return true;
}

/**
Обработчик разбора пришедшего через хук сообщения
*/
void tgWebhookDispatcher(HTTPServerRequest req, HTTPServerResponse res)
{
	debug {
		logInfo("==========");
		logInfo("Req:\n" ~ to!string(req.json()));
	}
	res.contentType("application/json");
	string resJson;
	if("reply_to_message" in req.json["message"]) {
		debug { logInfo("inHasReply"); }
		if("entities" in req.json["message"] && "type" in req.json["message"]["entities"][0] && req.json["message"]["entities"][0]["type"].get!string == "bot_command")
		{
			debug { logInfo("inHasBotCommand"); }
			switch(req.json["message"]["text"].get!string)
			{
				case "/vonneysetvideo@" ~ botName:
				case "/vonneysetvideo":
				debug { logInfo("inCommandVonneysetvideo"); }
				debug { logInfo("inCheckWantedRights"); }
				Json result = tgSend(q"[{"method":"getChatMember","chat_id":]"
					~ to!string(req.json["message"]["chat"]["id"])
					~ q"[,"user_id":]"
					~ to!string(req.json["message"]["from"]["id"])
					~ "}");
				if("ok" in result)
				{
					debug { logInfo("inCheckResult"); }
					if(result["ok"] && (result["result"]["status"] == "creator" || (result["result"]["status"] == "administrator" && result["result"]["can_change_info"])))
					{
						debug { logInfo("inResultOk"); }
						debug { logInfo("inCheckVideo"); }
						string type;
						if("document" in req.json["message"]["reply_to_message"] && "mime_type" in req.json["message"]["reply_to_message"]["document"] && req.json["message"]["reply_to_message"]["document"]["mime_type"] == "video/mp4") type = "document";
						if("video" in req.json["message"]["reply_to_message"] && "mime_type" in req.json["message"]["reply_to_message"]["video"] && req.json["message"]["reply_to_message"]["video"]["mime_type"] == "video/mp4") type = "video";
						if(type)
						{
							debug { logInfo("inChangeVideo"); }
							auto conn = client.lockConnection();
							immutable qresult1 = conn.execStatement("select * from videos where chat_id = "
								~ to!string(req.json["message"]["chat"]["id"])
								~ ";",
								ValueFormat.BINARY);
							debug { logInfo("qresult1:\n" ~ qresult1.toString); }
							auto qanswer1 = qresult1.getAnswer;
							if(qanswer1.length == 0)
							{
								debug { logInfo("inInsertVideo"); }
								debug { logInfo("req.json.message.reply_to_message." ~ type ~ ".file_id = " ~ req.json["message"]["reply_to_message"][type]["file_id"].get!string); }
								immutable qresult2 = conn.execStatement("insert into videos (chat_id, video, type) values ("
									~ to!string(req.json["message"]["chat"]["id"])
									~ ", '"
									~ req.json["message"]["reply_to_message"][type]["file_id"].get!string
									~ "', '"
									~ type
									~ "');",
									ValueFormat.BINARY);
								debug { logInfo("qresult2:\n" ~ qresult2.toString); }
							}
							else
							{
								debug { logInfo("inUpdateVideo"); }
								immutable qresult2 = conn.execStatement("update videos set video = '"
									~ req.json["message"]["reply_to_message"][type]["file_id"].get!string
									~ "', type = '"
									~ type
									~ "' where chat_id = "
									~ to!string(req.json["message"]["chat"]["id"])
									~ ";",
									ValueFormat.BINARY);
								debug { logInfo("qresult2:\n" ~ qresult2.toString); }
							}
							destroy(conn);
							auto createMessageResult = createMessageForChat(req.json, "Гтво", resJson);
							debug { logInfo("createMessageResult: " ~ to!string(createMessageResult)); }
						}
						else
						{
							debug { logInfo("inResultNotOk"); }
							auto createMessageResult = createMessageForChat(req.json, "Эт н вдео", resJson);
							debug { logInfo("createMessageResult: " ~ to!string(createMessageResult)); }
						}
						
					}
					else
					{
						debug { logInfo("inResultNotOk"); }
						auto createMessageResult = createMessageForChat(req.json, "Т н адмн", resJson);
						debug { logInfo("createMessageResult: " ~ to!string(createMessageResult)); }
					}
				}
				else
				{
					debug { logInfo("inResultError"); }
					auto createMessageResult = createMessageForChat(req.json, "Чт-т н в прдке", resJson);
					debug { logInfo("createMessageResult: " ~ to!string(createMessageResult)); }
				}
				break;
				default:
				break;
			}
		}
	}
	else
	{
		debug { logInfo("inHasNoReply"); }
		if("new_chat_participant" in req.json["message"] && !req.json["message"]["new_chat_participant"]["is_bot"])
		{
			debug { logInfo("inNewParticipantNotBot"); }
			auto conn = client.lockConnection();
			immutable qresult1 = conn.execStatement("select * from users where user_id = "
				~ to!string(req.json["message"]["new_chat_participant"]["id"])
				~ " and chat_id = "
				~ to!string(req.json["message"]["chat"]["id"])
				~ ";",
				ValueFormat.BINARY);
			debug { logInfo("qresult1:\n" ~ qresult1.toString); }
			auto qanswer1 = qresult1.getAnswer;
			debug { logInfo("qanswer1.length = " ~ to!string(qanswer1.length)); }
			if(qanswer1.length == 0)
			{
				debug { logInfo("inInsertUser"); }
				debug { logInfo("req.json.message.new_chat_participant.id = " ~ to!string(req.json["message"]["new_chat_participant"]["id"]) ~ "\nreq.json.message.chat.id = " ~ to!string(req.json["message"]["chat"]["id"])); }
				immutable qresult2 = conn.execStatement("insert into users (user_id, chat_id) values ("
					~ to!string(req.json["message"]["new_chat_participant"]["id"])
					~ ", "
					~ to!string(req.json["message"]["chat"]["id"])
					~ ");",
					ValueFormat.BINARY);
				debug { logInfo("qresult2:\n" ~ qresult2.toString); }
			}
			else
			{
				debug { logInfo("inSendVideo"); }
				immutable qresult2 = conn.execStatement("select video, type from videos where chat_id = "
					~ to!string(req.json["message"]["chat"]["id"])
					~ ";",
					ValueFormat.BINARY);
				debug { logInfo("qresult2:\n" ~ qresult2.toString); }
				auto qanswer2 = qresult2.getAnswer;
				if(qanswer2.length > 0)
				{
					debug { logInfo("inVideoFound"); }
					debug { logInfo("qresult2[0][0] = " ~ qresult2[0][0].toString.split(":")[0]); }
					string video = qresult2[0][0].toString.split(":")[0];
					string type = qresult2[0][1].toString.split(":")[0];
					string cType;
					if(type == q"["document"]") cType = "sendDocument";
					if(type == q"["video"]") cType = "sendVideo";
					string tgSendReq = q"[{"method":"]"
						~ cType
						~ q"[","chat_id":]"
						~ to!string(req.json["message"]["chat"]["id"])
						~ q"[,"disable_notification":"true",]"
						~ type
						~ ":"
						~ video
						~ q"[,"caption":"Опять прыгаешь?"}]";
					debug { logInfo("tgSendReq = " ~ tgSendReq); }
					Json result = tgSend(tgSendReq);
					if("ok" in result)
					{
						debug { logInfo("inResultOk"); }
					}
					else
					{
						debug { logInfo("inResultError"); }
						auto createMessageResult = createMessageForChat(req.json, "Чт-т н в прдке с вдео", resJson);
						debug { logInfo("createMessageResult: " ~ to!string(createMessageResult)); }
					}
				}
			}
			destroy(conn);
		}
		else
		if("entities" in req.json["message"] && "type" in req.json["message"]["entities"][0] && req.json["message"]["entities"][0]["type"].get!string == "bot_command")
		{
			debug { logInfo("inHasBotCommand"); }
			switch(req.json["message"]["text"].get!string)
			{
				case "/vonneysetvideo@" ~ botName:
				case "/vonneysetvideo":
				debug { logInfo("inCommandVonneysetvideo"); }
				debug { logInfo("inCheckWantedRights"); }
				Json result = tgSend(q"[{"method":"getChatMember","chat_id":]"
					~ to!string(req.json["message"]["chat"]["id"])
					~ q"[,"user_id":]"
					~ to!string(req.json["message"]["from"]["id"])
					~ "}");
				if("ok" in result)
				{
					debug { logInfo("inCheckResult"); }
					if(result["ok"] && (result["result"]["status"] == "creator" || (result["result"]["status"] == "administrator" && result["result"]["can_change_info"])))
					{
						debug { logInfo("inResultOk"); }
						auto createMessageResult = createMessageForChat(req.json, "Згрзи вдео в чт и вплни эт кмнду в рпле этго вдео", resJson);
						debug { logInfo("createMessageResult: " ~ to!string(createMessageResult)); }
					}
					else
					{
						debug { logInfo("inResultNotOk"); }
						auto createMessageResult = createMessageForChat(req.json, "Т н адмн", resJson);
						debug { logInfo("createMessageResult: " ~ to!string(createMessageResult)); }
					}
				}
				else
				{
					debug { logInfo("inResultError"); }
					auto createMessageResult = createMessageForChat(req.json, "Чт-т н в прдке", resJson);
					debug { logInfo("createMessageResult: " ~ to!string(createMessageResult)); }
				}
				break;
				default:
				break;
			}

		}
	}
	debug { logInfo("FINAL resJson:\n" ~ resJson); }
	res.writeBody(resJson);
}
