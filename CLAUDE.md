Idea.md contains the high-level idea reference it frequently to ensure the implementation stays aligned with the original vision.
STATUS.md contains the current status of the project, including which tasks are completed, in progress, or pending. TODO.md contains the detailed task breakdown for each day of development, along with exit criteria to ensure that each task is completed successfully before moving on to the next one.
Documentation for , reference for ENS related code doubts: https://docs.ens.domains/llms-full.txt
If I ask you to continue working check TODO.md for the next task and its exit criteria, and focus on completing that task in isolation. 
Mark everything that is mocked explicitly as such, and keep the real on-chain mechanics front-and-center. 
Keep each session about a single bounded task. Remind me to start a new session if I start to deviate. 
When asked questions or in doubt always reference actual code to see what's actually happening instead of relying on memory or assumptions. 
Keep each task focused on a single piece of functionality that can be completed and tested in isolation. Avoid trying to build multiple features at once.
Don't assume large code writes to be correct without verifying it. Always write tests for significant functionality and run them frequently. If something is broken, fix it immediately before moving on.
There is no legacy code to maintain, so don't be afraid to refactor or throw away code that isn't working. Any problem that is fixable at the time of discovery should be fixed immediately rather than deferred.
If any task requires me to do something outside of coding (e.g. getting api keys, setting up infrastructure), without which the task cannot be completed, put it in myTasks.md and prompt me to complete it.
