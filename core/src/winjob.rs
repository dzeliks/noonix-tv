// windows: helper processes a build starts live in one job object that closes with noonix tv, so
// they end with it even on a crash (what PR_SET_PDEATHSIG does on linux)
use once_cell::sync::Lazy;
use windows_sys::Win32::Foundation::HANDLE;
use windows_sys::Win32::System::JobObjects::{
    AssignProcessToJobObject, CreateJobObjectW, JobObjectExtendedLimitInformation, SetInformationJobObject,
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION, JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE,
};

struct Job(HANDLE);
unsafe impl Send for Job {}
unsafe impl Sync for Job {}

static JOB: Lazy<Option<Job>> = Lazy::new(|| unsafe {
    let job = CreateJobObjectW(std::ptr::null(), std::ptr::null());
    if job.is_null() {
        return None;
    }
    let mut info: JOBOBJECT_EXTENDED_LIMIT_INFORMATION = std::mem::zeroed();
    info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    let ok = SetInformationJobObject(
        job,
        JobObjectExtendedLimitInformation,
        &info as *const _ as *const _,
        std::mem::size_of::<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>() as u32,
    );
    (ok != 0).then_some(Job(job))
});

pub fn adopt(child: &tokio::process::Child) {
    let (Some(job), Some(handle)) = (JOB.as_ref(), child.raw_handle()) else { return };
    unsafe {
        if AssignProcessToJobObject(job.0, handle as HANDLE) == 0 {
            tracing::warn!("couldn't tie the service to noonix tv's lifetime");
        }
    }
}
