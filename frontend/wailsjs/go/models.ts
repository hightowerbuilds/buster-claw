export namespace calendar {
	
	export class Event {
	    id: string;
	    date: string;
	    title: string;
	    notes?: string;
	
	    static createFrom(source: any = {}) {
	        return new Event(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.id = source["id"];
	        this.date = source["date"];
	        this.title = source["title"];
	        this.notes = source["notes"];
	    }
	}

}

export namespace delivery {
	
	export class Destination {
	    name: string;
	    type: string;
	    url?: string;
	    token?: string;
	    chatId?: string;
	    enabled: boolean;
	
	    static createFrom(source: any = {}) {
	        return new Destination(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.name = source["name"];
	        this.type = source["type"];
	        this.url = source["url"];
	        this.token = source["token"];
	        this.chatId = source["chatId"];
	        this.enabled = source["enabled"];
	    }
	}

}

export namespace hooks {
	
	export class Hook {
	    name: string;
	    event: string;
	    type: string;
	    target: string;
	    async: boolean;
	    enabled: boolean;
	
	    static createFrom(source: any = {}) {
	        return new Hook(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.name = source["name"];
	        this.event = source["event"];
	        this.type = source["type"];
	        this.target = source["target"];
	        this.async = source["async"];
	        this.enabled = source["enabled"];
	    }
	}

}

export namespace ingest {
	
	export class Cookie {
	    name: string;
	    value: string;
	    domain: string;
	    path: string;
	
	    static createFrom(source: any = {}) {
	        return new Cookie(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.name = source["name"];
	        this.value = source["value"];
	        this.domain = source["domain"];
	        this.path = source["path"];
	    }
	}
	export class Source {
	    url: string;
	    type: string;
	    tags: string[];
	    name?: string;
	    cookies?: Cookie[];
	    browser_engine?: string;
	
	    static createFrom(source: any = {}) {
	        return new Source(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.url = source["url"];
	        this.type = source["type"];
	        this.tags = source["tags"];
	        this.name = source["name"];
	        this.cookies = this.convertValues(source["cookies"], Cookie);
	        this.browser_engine = source["browser_engine"];
	    }
	
		convertValues(a: any, classs: any, asMap: boolean = false): any {
		    if (!a) {
		        return a;
		    }
		    if (a.slice && a.map) {
		        return (a as any[]).map(elem => this.convertValues(elem, classs));
		    } else if ("object" === typeof a) {
		        if (asMap) {
		            for (const key of Object.keys(a)) {
		                a[key] = new classs(a[key]);
		            }
		            return a;
		        }
		        return new classs(a);
		    }
		    return a;
		}
	}

}

export namespace library {
	
	export class ReportMeta {
	    filename: string;
	    source_file: string;
	    source_url: string;
	    generated_at: string;
	    model: string;
	    intentions_used: boolean;
	    tags?: string[];
	
	    static createFrom(source: any = {}) {
	        return new ReportMeta(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.filename = source["filename"];
	        this.source_file = source["source_file"];
	        this.source_url = source["source_url"];
	        this.generated_at = source["generated_at"];
	        this.model = source["model"];
	        this.intentions_used = source["intentions_used"];
	        this.tags = source["tags"];
	    }
	}

}

export namespace main {
	
	export class AnalysisResult {
	    processedCount: number;
	    error?: string;
	
	    static createFrom(source: any = {}) {
	        return new AnalysisResult(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.processedCount = source["processedCount"];
	        this.error = source["error"];
	    }
	}
	export class ChatMessage {
	    role: string;
	    content: string;
	
	    static createFrom(source: any = {}) {
	        return new ChatMessage(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.role = source["role"];
	        this.content = source["content"];
	    }
	}
	export class DocumentInfo {
	    filename: string;
	    path: string;
	    date: string;
	    sourceUrl: string;
	    name: string;
	    excerpt: string;
	
	    static createFrom(source: any = {}) {
	        return new DocumentInfo(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.filename = source["filename"];
	        this.path = source["path"];
	        this.date = source["date"];
	        this.sourceUrl = source["sourceUrl"];
	        this.name = source["name"];
	        this.excerpt = source["excerpt"];
	    }
	}
	export class IngestResult {
	    savedCount: number;
	    error?: string;
	
	    static createFrom(source: any = {}) {
	        return new IngestResult(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.savedCount = source["savedCount"];
	        this.error = source["error"];
	    }
	}
	export class MemoryEntry {
	    index: number;
	    createdAt: string;
	    text: string;
	
	    static createFrom(source: any = {}) {
	        return new MemoryEntry(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.index = source["index"];
	        this.createdAt = source["createdAt"];
	        this.text = source["text"];
	    }
	}
	export class PendingFile {
	    filename: string;
	    path: string;
	    date: string;
	
	    static createFrom(source: any = {}) {
	        return new PendingFile(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.filename = source["filename"];
	        this.path = source["path"];
	        this.date = source["date"];
	    }
	}
	export class ProviderInfo {
	    name: string;
	    type: string;
	    baseUrl: string;
	    model: string;
	    active: boolean;
	    hasKey: boolean;
	
	    static createFrom(source: any = {}) {
	        return new ProviderInfo(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.name = source["name"];
	        this.type = source["type"];
	        this.baseUrl = source["baseUrl"];
	        this.model = source["model"];
	        this.active = source["active"];
	        this.hasKey = source["hasKey"];
	    }
	}
	export class WebhookInfo {
	    name: string;
	    action: string;
	    customCmd?: string;
	    deliverTo?: string;
	    enabled: boolean;
	    hasSecret: boolean;
	
	    static createFrom(source: any = {}) {
	        return new WebhookInfo(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.name = source["name"];
	        this.action = source["action"];
	        this.customCmd = source["customCmd"];
	        this.deliverTo = source["deliverTo"];
	        this.enabled = source["enabled"];
	        this.hasSecret = source["hasSecret"];
	    }
	}

}

export namespace orchestrator {
	
	export class QueueEntry {
	    filename: string;
	    path: string;
	    status: string;
	    progress: number;
	    error?: string;
	    report?: string;
	    model?: string;
	
	    static createFrom(source: any = {}) {
	        return new QueueEntry(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.filename = source["filename"];
	        this.path = source["path"];
	        this.status = source["status"];
	        this.progress = source["progress"];
	        this.error = source["error"];
	        this.report = source["report"];
	        this.model = source["model"];
	    }
	}

}

export namespace scheduler {
	
	export class JobState {
	    id: string;
	    type: string;
	    cron: string;
	    enabled: boolean;
	    customCmd?: string;
	    deliverTo?: string;
	    nextRun: string;
	    lastRun: string;
	    lastError: string;
	
	    static createFrom(source: any = {}) {
	        return new JobState(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.id = source["id"];
	        this.type = source["type"];
	        this.cron = source["cron"];
	        this.enabled = source["enabled"];
	        this.customCmd = source["customCmd"];
	        this.deliverTo = source["deliverTo"];
	        this.nextRun = source["nextRun"];
	        this.lastRun = source["lastRun"];
	        this.lastError = source["lastError"];
	    }
	}

}

